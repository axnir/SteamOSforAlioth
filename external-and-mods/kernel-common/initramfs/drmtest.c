/*
 * drmtest — force one modeset and paint the screen a solid colour.
 *
 * Not a driver and not a tool; it exists to answer one question during
 * phase 1 on the OnePlus 8 Pro: with no compositor and no userspace, does
 * the panel actually light up when something commits a frame?
 *
 * The situation that motivated it: everything in the display chain probes
 * (dispcc, mdss, dsi host, dsi phy, panel, backlight), the DSI interrupt
 * fires continuously, and yet /sys/kernel/debug/dri/0/state is empty --
 * no active commit -- and the screen stays black. fbcon creates a
 * framebuffer but nothing keeps feeding it, so DRM sits idle. If a single
 * explicit legacy modeset makes the panel light, the hardware is fine and
 * the black screen is simply "nobody is driving the display yet". If it
 * stays black, the problem is below DRM and belongs to DSI/panel init.
 *
 * Deliberately uses the legacy drmModeSetCrtc path: it needs no atomic
 * properties, no planes, and no libdrm. It talks to /dev/dri/card0 with
 * raw ioctls so it can be built as a static arm64 binary with nothing but
 * a cross compiler.
 *
 * Usage: drmtest [r g b]     (defaults to white)
 *
 * Exit 0 on a successful commit. Every failure prints what ioctl failed
 * and what the kernel returned, because a silent failure here is
 * indistinguishable from a black panel.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

#define MAX_CONNECTORS 32

static void die(const char *what)
{
	fprintf(stderr, "drmtest: %s: %s\n", what, strerror(errno));
	exit(1);
}

static int get_resources(int fd, struct drm_mode_card_res *res)
{
	memset(res, 0, sizeof(*res));
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, res) < 0)
		return -1;
	return 0;
}

int main(int argc, char **argv)
{
	uint8_t r = 0xff, g = 0xff, b = 0xff;

	if (argc == 4) {
		r = (uint8_t)strtoul(argv[1], NULL, 0);
		g = (uint8_t)strtoul(argv[2], NULL, 0);
		b = (uint8_t)strtoul(argv[3], NULL, 0);
	}

	int fd = open("/dev/dri/card0", O_RDWR);
	if (fd < 0)
		die("open /dev/dri/card0");

	struct drm_mode_card_res res;
	if (get_resources(fd, &res) < 0)
		die("GETRESOURCES (counts)");

	printf("drmtest: %u connectors, %u crtcs, %u encoders, %u fbs\n",
	       res.count_connectors, res.count_crtcs, res.count_encoders,
	       res.count_fbs);

	uint32_t *conn_ids = calloc(res.count_connectors, sizeof(uint32_t));
	uint32_t *crtc_ids = calloc(res.count_crtcs, sizeof(uint32_t));
	uint32_t *enc_ids = calloc(res.count_encoders, sizeof(uint32_t));
	if (!conn_ids || !crtc_ids || !enc_ids)
		die("calloc");

	res.connector_id_ptr = (uintptr_t)conn_ids;
	res.crtc_id_ptr = (uintptr_t)crtc_ids;
	res.encoder_id_ptr = (uintptr_t)enc_ids;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0)
		die("GETRESOURCES (ids)");

	/* Find the first connected connector. */
	uint32_t conn = 0, mode_idx = 0;
	struct drm_mode_modeinfo mode;
	memset(&mode, 0, sizeof(mode));

	for (uint32_t i = 0; i < res.count_connectors; i++) {
		struct drm_mode_get_connector c;
		memset(&c, 0, sizeof(c));
		c.connector_id = conn_ids[i];
		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) {
			fprintf(stderr, "drmtest: conn %u: %s\n", conn_ids[i],
				strerror(errno));
			continue;
		}
		printf("drmtest: conn %u type=%u conn=%u enc=%u modes=%u\n",
		       conn_ids[i], c.connector_type, c.connection,
		       c.encoder_id, c.count_modes);

		if (c.connection != 1 /* DRM_MODE_CONNECTED */)
			continue;
		if (c.count_modes == 0)
			continue;

		/*
		 * Re-fetch with space for the mode list. The kernel writes the
		 * counts back on every GETCONNECTOR, so clear them first and
		 * set only the id and the pointers -- leaving a stale
		 * count_encoders from the previous call makes the kernel try
		 * to fill an encoder array we did not supply.
		 */
		struct drm_mode_modeinfo *modes =
			calloc(c.count_modes, sizeof(*modes));
		if (!modes)
			die("calloc modes");
		struct drm_mode_get_connector c2;
		memset(&c2, 0, sizeof(c2));
		c2.connector_id = c.connector_id;
		c2.count_modes = c.count_modes;
		c2.modes_ptr = (uintptr_t)modes;
		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c2) < 0)
			die("GETCONNECTOR (modes)");
		c = c2;

		conn = conn_ids[i];
		mode = modes[0];
		mode_idx = 0;
		printf("drmtest: using %ux%u @%uHz (%s)\n", mode.hdisplay,
		       mode.vdisplay, mode.vrefresh, mode.name);
		free(modes);
		break;
	}

	if (!conn) {
		fprintf(stderr, "drmtest: no connected connector with modes\n");
		close(fd);
		return 1;
	}

	/* Our own dumb buffer the size of the mode. */
	struct drm_mode_create_dumb cd;
	memset(&cd, 0, sizeof(cd));
	cd.width = mode.hdisplay;
	cd.height = mode.vdisplay;
	cd.bpp = 32;
	if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd) < 0)
		die("CREATE_DUMB");
	printf("drmtest: dumb handle=%u pitch=%u size=%llu\n", cd.handle,
	       cd.pitch, (unsigned long long)cd.size);

	struct drm_mode_fb_cmd fb;
	memset(&fb, 0, sizeof(fb));
	fb.width = cd.width;
	fb.height = cd.height;
	fb.pitch = cd.pitch;
	fb.bpp = cd.bpp;
	fb.depth = 24;
	fb.handle = cd.handle;
	if (ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fb) < 0)
		die("ADDFB");
	printf("drmtest: fb_id=%u\n", fb.fb_id);

	/* Map it and fill with the colour. XRGB8888. */
	struct drm_mode_map_dumb md;
	memset(&md, 0, sizeof(md));
	md.handle = cd.handle;
	if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md) < 0)
		die("MAP_DUMB");

	void *map = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED,
			 fd, md.offset);
	if (map == MAP_FAILED)
		die("mmap dumb");

	uint32_t px = (r << 16) | (g << 8) | b;
	for (uint32_t y = 0; y < cd.height; y++) {
		uint32_t *row = (uint32_t *)((uint8_t *)map + (size_t)y * cd.pitch);
		for (uint32_t x = 0; x < cd.width; x++)
			row[x] = px;
	}
	msync(map, cd.size, MS_SYNC);

	/*
	 * The commit. Legacy SetCrtc takes the connector, its first supported
	 * encoder, the framebuffer and the mode; it is the smallest thing
	 * that can bring a pipe up.
	 */
	struct drm_mode_get_connector cc;
	memset(&cc, 0, sizeof(cc));
	cc.connector_id = conn;
	if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &cc) < 0)
		die("GETCONNECTOR (encoders)");
	if (cc.count_encoders == 0) {
		fprintf(stderr, "drmtest: connector has no encoders\n");
		return 1;
	}
	uint32_t *encs = calloc(cc.count_encoders, sizeof(uint32_t));
	struct drm_mode_get_connector cc2;
	memset(&cc2, 0, sizeof(cc2));
	cc2.connector_id = cc.connector_id;
	cc2.count_encoders = cc.count_encoders;
	cc2.encoders_ptr = (uintptr_t)encs;
	if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &cc2) < 0)
		die("GETCONNECTOR (encoder ids)");
	cc = cc2;

	struct drm_mode_get_encoder enc;
	memset(&enc, 0, sizeof(enc));
	enc.encoder_id = encs[0];
	if (ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &enc) < 0)
		die("GETENCODER");

	uint32_t crtc = enc.crtc_id;
	if (!crtc && enc.possible_crtcs) {
		for (uint32_t i = 0; i < res.count_crtcs; i++) {
			if (enc.possible_crtcs & (1u << i)) {
				crtc = crtc_ids[i];
				break;
			}
		}
	}
	if (!crtc) {
		fprintf(stderr, "drmtest: no usable crtc\n");
		return 1;
	}
	printf("drmtest: encoder=%u crtc=%u\n", enc.encoder_id, crtc);

	struct drm_mode_crtc set;
	memset(&set, 0, sizeof(set));
	set.crtc_id = crtc;
	set.fb_id = fb.fb_id;
	set.mode_valid = 1;
	memcpy(&set.mode, &mode, sizeof(mode));
	uint32_t one = conn;
	set.set_connectors_ptr = (uintptr_t)&one;
	set.count_connectors = 1;

	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &set) < 0)
		die("SETCRTC");

	printf("drmtest: committed fb %u to crtc %u -- screen should be "
	       "%02x%02x%02x\n", fb.fb_id, crtc, r, g, b);

	/*
	 * Dump what the kernel thinks happened, from inside the same process
	 * that did the commit. Reading it afterwards from the shell does not
	 * work: DRM's debugfs state is empty once no commit is in flight, and
	 * by then the interesting transients are gone.
	 */
	char path[128];
	const char *files[] = {
		"/sys/kernel/debug/dri/0/state",
		"/sys/class/graphics/fb0/blank",
		"/sys/class/backlight/ae94000.dsi.0/actual_brightness",
		"/sys/class/drm/card0-DSI-1/dpms",
		"/sys/class/drm/card0-DSI-1/status",
	};
	for (unsigned fi = 0; fi < sizeof(files) / sizeof(files[0]); fi++) {
		int f = open(files[fi], O_RDONLY);
		if (f < 0) {
			printf("drmtest: %s: %s\n", files[fi], strerror(errno));
			continue;
		}
		char buf[2048];
		ssize_t n = read(f, buf, sizeof(buf) - 1);
		close(f);
		if (n <= 0) {
			printf("drmtest: %s: (empty)\n", files[fi]);
			continue;
		}
		buf[n] = 0;
		/* Only the first few lines matter and the terminal is slow. */
		printf("drmtest: --- %s ---\n%s\n", files[fi], buf);
	}
	(void)path;

	/*
	 * Leave the buffer mapped; the kernel keeps scanning it out. 30s is
	 * long enough for the reader to look at the panel and for the shell
	 * to come back, and short enough not to hold the DRM lock forever.
	 */
	sleep(30);
	return 0;
}
