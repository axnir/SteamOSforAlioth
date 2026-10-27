// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung ANA6706 1440x3168 DSC command-mode panel, as used on the
 * OnePlus 8 Pro (instantnoodlep / IN2020).
 *
 * Shape copied from panel-samsung-sofef00.c (another OnePlus Samsung DSC
 * panel in mainline) and from this tree's panel-samsung-ams667xx01.c
 * (the Xiaomi alioth port, patches/0017), which was forward-ported to the
 * same 7.2 API this driver targets. Where the two disagree about API
 * shape, 0017 wins -- it is the one that actually builds here.
 *
 * Everything numeric in this file was read off the running phone on
 * 2026-10-25 from /sys/firmware/devicetree/base, not copied from a vendor
 * .dtsi or from a wiki:
 *
 *   panel-name   "samsung ana6706 dsc cmd mode panel"
 *   cmdline      msm_drm.dsi_display0=qcom,mdss_dsi_samsung_ana6706_dsc_cmd
 *   type         dsi_cmd_mode, burst_mode, DSC
 *   reset-gpio   tlmm 75      te-gpio  tlmm 66
 *   bl           bl_ctrl_dcs, bl-max-level 0x7ff (2047)
 *
 * Four timings exist on the device. This driver exposes the two 1440x3168
 * ones and the two 1080x2376 ones, in the order the vendor DT lists them,
 * so the DSI mode chosen at probe time can be pinned from userspace.
 *
 * The DCS initialisation sequence in ana6706_init_sequence() was
 * transcribed mechanically from the vendor device tree on the running
 * phone (2026-10-25):
 *
 *   qcom,mdss-dsi-display-timings/timing@1/qcom,mdss-dsi-on-command
 *
 * 668 bytes, 61 packets. Qualcomm's packing is, per packet:
 *
 *   [dtype][last][wait_hi][wait_lo][delay_ms][len_hi][len_lo][payload...]
 *
 * where dtype 0x05 is a DCS short write, 0x15 a DCS long write, 0x39 a
 * generic long write and 0x07 a generic short write; `delay_ms` is a
 * post-command sleep, and only three packets carry one (11 ms after
 * exit-sleep, 11 ms after one page-lock disable, 111 ms after another).
 * The transcription consumed all 668 bytes with no remainder, which is
 * the check that the record layout is right -- a wrong header size
 * desynchronises immediately and leaves a remainder.
 *
 * The other three timings' sequences are 638 bytes and differ in exactly
 * one place: timing@0 (1080x2376@60) writes 0x60 = 0x02 where timing@1
 * writes 0x22, and timing@1 adds a 0xb9/0xb0/0xb9 group before display-on.
 * 0x60 is the panel's refresh-rate mode selection, so those bytes track
 * the frame rate rather than the panel model. ana6706_init_sequence()
 * covers timing@1; driving another timing needs its own variant.
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#include <video/mipi_display.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <drm/drm_probe_helper.h>

/*
 * Supply names follow the vendor DT's qcom,panel-supply-entries and
 * qcom,iris-supply-entries. The panel node in the DTS must provide these
 * or probe fails loudly (which is the point -- a silently missing rail is
 * a black screen with no error).
 */
/*
 * Exactly the supplies the vendor DT lists for this panel, and no more.
 *
 * An earlier revision also asked for "avdd". Nothing provides it, so the
 * driver got a dummy regulator for it and the boot log said so on every
 * boot:
 *
 *   panel-oneplus-ana6706 ae94000.dsi.0: supply avdd not found,
 *   using dummy regulator
 *
 * A dummy regulator is harmless in itself -- nothing tries to turn it on --
 * but the real point is that the vendor DT has no avdd entry at all:
 * qcom,panel-supply-entries@0/1/2 are vddi(1.8V) / vddr(1.3V) / vci(3.0V)
 * and qcom,iris-supply-entries@0 is px_v18r(1.8V). Asking for a supply the
 * hardware does not have only produces noise in the log that looks like a
 * power problem, which is exactly the kind of false lead this port spent
 * time on.
 */
static const struct regulator_bulk_data ana6706_supplies[] = {
	{ .supply = "vddi" },		/* 1.8V, post-on-sleep 2ms */
	{ .supply = "vddr" },		/* 1.3V, post-off-sleep 1ms */
	{ .supply = "vci" },		/* 3.0V */
	{ .supply = "px_v18r" },	/* 1.8V, Pixelworks Iris */
};

struct ana6706 {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct regulator_bulk_data *supplies;
	struct gpio_desc *reset_gpio;
	/* Pixelworks Iris ABYP-ready, input. NULL if the DT omits it. */
	struct gpio_desc *iris_abyp_ready_gpio;
};

/*
 * Note: no separate struct panel_desc here, unlike the alioth driver.
 * The vendor DT gives four timings and all of them are DSC with the same
 * topology; keeping them in one table with a --dsc index is simpler than
 * a desc-per-timing arrangement, and get_modes() emits all four so
 * userspace can pick.
 */

#define ana6706_test_key_on(ctx)  mipi_dsi_dcs_write_seq_multi(ctx, 0xf0, 0x5a, 0x5a)
#define ana6706_test_key_off(ctx) mipi_dsi_dcs_write_seq_multi(ctx, 0xf0, 0xa5, 0xa5)

static inline struct ana6706 *to_ana6706(struct drm_panel *panel)
{
	return container_of(panel, struct ana6706, panel);
}

/*
 * Reset: the vendor DT's qcom,mdss-dsi-reset-sequence is
 * <10 5 20>, i.e. assert-low for 10 ms, then release, wait 5 ms, then
 * (for a DSC command panel) the panel keeps its rails. Delays rounded
 * into usleep_range() ranges as mainline drivers do.
 */
/*
 * Reset pulse.
 *
 * Vendor DT: qcom,mdss-dsi-reset-sequence = <1 10>, <0 10>, <1 10>, i.e.
 * the physical line goes high, low, high again with 10 ms at each step,
 * ending de-asserted.
 *
 * The reset GPIO is declared GPIO_ACTIVE_LOW, so gpiod_set_value() takes
 * the *logical* value and the polarity inverts: logical 1 drives the pin
 * low, which is the asserted (in reset) state. Writing the vendor's
 * physical levels straight into gpiod_set_value() therefore produces
 * exactly the opposite sequence -- and that is not a subtle failure: with
 * the line ending asserted, DCS reads time out (-110) instead of
 * returning power_mode.
 *
 * So the logical sequence is 0, 1, 0: assert, release, and stay released.
 * The trailing low (physical high) is what leaves the panel running.
 */
static void ana6706_reset(struct ana6706 *ctx)
{
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);	/* physical high */
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);	/* physical low: reset */
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);	/* physical high: release */
	usleep_range(10000, 11000);
}

static int ana6706_init_sequence(struct ana6706 *ctx)
{
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };

	/*
	 * dev_info, not dev_dbg: whether this function runs at all is the
	 * single fact that distinguishes "the panel is being initialised and
	 * the picture is wrong" from "nothing has ever talked to the panel".
	 * A silent skip is the failure mode that cost the most time here --
	 * SETCRTC returned success, the DSI TE interrupt kept firing, and
	 * the panel stayed dark with no clue in the log. Leave it at
	 * dev_info until the panel is proven to light up.
	 */
	dev_info(&dsi->dev, "init sequence start\n");

	/* --- vendor DCS init, transcribed from the phone's DT --- */

	/*
	 * 120 ms after exit_sleep, not the vendor's 11 ms, and read back to
	 * confirm it worked.
	 *
	 * Measured on hardware: with 11 ms the sequence runs to completion and
	 * get_power_mode still reports 0x0c -- bit4 (sleep_out) is 0, i.e. the
	 * panel says it is still asleep while also claiming display-on. That
	 * is the state that produces "backlight flashes once, then black":
	 * the DCS writes land, brightness takes effect, but the panel never
	 * leaves sleep so it never scans out a frame.
	 *
	 * The vendor's 11 ms is what their path gets away with because the
	 * bootloader has already woken the panel; from cold, mainline owns
	 * reset and has to wait the full sleep-out time. 120 ms is also the
	 * MIPI DCS worst case for T SOT.
	 */
	mipi_dsi_dcs_exit_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_usleep_range(&dsi_ctx, 120000, 121000);

	/*
	 * Confirm sleep-out actually took, right here, so a future run can
	 * tell this apart from the many later steps that also read
	 * power_mode. bit4 set means the panel left sleep.
	 */
	if (!dsi_ctx.accum_err) {
		u8 pm_after = 0;
		int ra = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &pm_after, 1);
		dev_info(&dsi->dev, "sleep-out check: r=%d power_mode=0x%02x sleep_out=%d\n",
			 ra, pm_after, !!(pm_after & 0x10));
	}
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x09);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb5, 0x08);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x22);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf5, 0x65);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x38);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf5, 0x0f);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x56);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf5, 0xc4);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xcb, 0xff, 0xff);

	/* bisect probe: after#15_cmd15 */
	if (!dsi_ctx.accum_err) {
		u8 bp = 0;
		int br = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &bp, 1);
		dev_info(&dsi->dev, "bisect after#15_cmd15: r=%d power_mode=0x%02x sleep_out=%d\n",
			 br, bp, !!(bp & 0x10));
	}
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf7, 0x0f);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_usleep_range(&dsi_ctx, 11000, 12000);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	/*
	 * DSC compression mode. The vendor sequence carries this as
	 * dtype 0x07 (DTYPE_COMPRESSION_MODE in mdss_dsi_cmd.h) with a
	 * single 0x01 byte, at packet 19 -- between the page-lock pair and
	 * the PPS write that follows at packet 21.
	 *
	 * An earlier revision sent it as mipi_dsi_generic_write_seq_multi(),
	 * which produces a Generic Long Write (dtype 0x29), not a
	 * compression-mode packet. The panel ignores it, so it stayed
	 * uncompressed while everything after packet 19 assumed otherwise:
	 * DCS reads return 0xff from around command 30, and by the end of the
	 * sequence power_mode reads 0x0c with sleep-out cleared.
	 */
	mipi_dsi_compression_mode_multi(&dsi_ctx, true);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xba, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx,
		0x9e, 0x11, 0x00, 0x00, 0x89, 0x30, 0x80, 0x09, 0x48, 0x04,
		0x38, 0x00, 0x48, 0x02, 0x1c, 0x02, 0x1c, 0x02, 0x00, 0x02,
		0x52, 0x00, 0x20, 0x06, 0x3b, 0x00, 0x07, 0x00, 0x0f, 0x01,
		0xb1, 0x01, 0x6a, 0x18, 0x00, 0x10, 0xf0, 0x03, 0x0c, 0x20,
		0x00, 0x06, 0x0b, 0x0b, 0x33, 0x0e, 0x1c, 0x2a, 0x38, 0x46,
		0x54, 0x62, 0x69, 0x70, 0x77, 0x79, 0x7b, 0x7d, 0x7e, 0x01,
		0x02, 0x01, 0x00, 0x09, 0x40, 0x09, 0xbe, 0x19, 0xfc, 0x19,
		0xfa, 0x19, 0xf8, 0x1a, 0x38, 0x1a, 0x78, 0x1a, 0xb6, 0x2a,
		0xb6, 0x2a, 0xf4, 0x2a, 0xf4, 0x4b, 0x34, 0x63, 0x74);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf7, 0x0f);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x35, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x2a, 0x00, 0x00, 0x04, 0x37);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x2b, 0x00, 0x00, 0x09, 0x47);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x05);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb9, 0x07, 0x02, 0x40, 0x23);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x0a);

	/* bisect probe: after#30_cmd30 */
	if (!dsi_ctx.accum_err) {
		u8 bp = 0;
		int br = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &bp, 1);
		dev_info(&dsi->dev, "bisect after#30_cmd30: r=%d power_mode=0x%02x sleep_out=%d\n",
			 br, bp, !!(bp & 0x10));
	}
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xfb, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x54);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb5, 0x48);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x99, 0x40);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x5c);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb1, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_usleep_range(&dsi_ctx, 111000, 112000);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x0b);

	/* bisect probe: after#45_cmd45 */
	if (!dsi_ctx.accum_err) {
		u8 bp = 0;
		int br = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &bp, 1);
		dev_info(&dsi->dev, "bisect after#45_cmd45: r=%d power_mode=0x%02x sleep_out=%d\n",
			 br, bp, !!(bp & 0x10));
	}
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb1, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb5, 0x13);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x53, 0x28);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x60, 0x22);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf7, 0x0f);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb9, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb9, 0x0c, 0x54, 0x00, 0x0b);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);

	/*
	 * Read the panel back. Writing a sequence successfully only proves the
	 * host queued it; it says nothing about whether the panel accepted it
	 * or is in the state we think. 0x0a (get_power_mode) answers with a
	 * byte whose bit 2 is "display on" and bits 1:0 are the level
	 * (0 = off, 1 = normal, 2 = idle, 3 = partial):
	 *
	 *   0x08..0x0b on a running panel
	 *   0x18/0x19 when it is still in sleep
	 *
	 * and 0x04 (get_error_count) for a checksum the panel saw on the
	 * link. Both are dev_info because the whole point is to see them in a
	 * log with no userspace to read them.
	 *
	 * A read that fails outright (accum_err != 0) is also informative: it
	 * means the link is one-way and nothing the panel says can be trusted.
	 */
	/*
	 * Set brightness explicitly, from the init sequence.
	 *
	 * bl_ctrl_dcs means the panel does its own backlight, controlled by
	 * DCS 0x51. The backlight subsystem only issues that write when
	 * something changes brightness, and in phase 1 nothing does -- there
	 * is no compositor, and the default value was already programmed at
	 * probe time -- so the panel could sit at whatever it powered up
	 * with. Writing it here makes "display on and lit" a property of the
	 * init sequence rather than of whether userspace happened to touch
	 * sysfs.
	 *
	 * 0x7ff/2 is what the backlight device reports as its default, so this
	 * matches what `cat actual_brightness` says rather than fighting it.
	 */
	/*
	 * 16-bit brightness (bl-max-level is 0x7ff). There is no _large_multi
	 * variant in this tree, so this one call is made outside the
	 * multi-context; its error is folded back in so the sequence still
	 * stops at the first failure like every other step.
	 */
	if (!dsi_ctx.accum_err) {
		int br = mipi_dsi_dcs_set_display_brightness_large(dsi, 0x7ff / 2);
		if (br < 0)
			dsi_ctx.accum_err = br;
	}
	mipi_dsi_usleep_range(&dsi_ctx, 20000, 21000);

	if (!dsi_ctx.accum_err) {
		u8 pm = 0xff, ec = 0xff;
		int r1 = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &pm, 1);
		int r2 = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_ERROR_COUNT_ON_DSI, &ec, 1);
		/*
		 * Read the panel's own view of itself, not just power_mode.
		 *
		 * power_mode was the only byte read back until now, and it
		 * reports 0x0c -- booster on, display on -- while the screen
		 * stays black. Either the panel is not where it claims to be,
		 * or the picture is reaching it and being discarded. These
		 * four registers separate the two:
		 *
		 *   0x0a get_power_mode        sleep/display/booster bits
		 *   0x0d get_display_mode      normal vs partial vs idle
		 *   0x0e get_signal_mode       video vs command, TE, polarity
		 *   0x0f get_diagnostic_result frame sync / tearing / underrun
		 *   0x52 get_display_brightness  what the panel thinks DBV is
		 *
		 * 0x0f is the interesting one: its low bits report frame sync
		 * and tearing-effect errors, so a panel that is refreshed but
		 * not showing anything should say so there.
		 */
		u8 dm = 0, sm = 0, diag = 0;
		u16 dbv = 0;
		int r3 = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_DISPLAY_MODE, &dm, 1);
		int r4 = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_SIGNAL_MODE, &sm, 1);
		int r5 = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_DIAGNOSTIC_RESULT, &diag, 1);
		int r6 = mipi_dsi_dcs_get_display_brightness_large(dsi, &dbv);

		dev_info(&dsi->dev, "readback: power_mode=%d/0x%02x "
			 "display_mode=%d/0x%02x signal_mode=%d/0x%02x "
			 "diag=%d/0x%02x brightness=%d/%u err_count=%d/0x%02x\n",
			 r1, pm, r3, dm, r4, sm, r5, diag, r6, dbv, r2, ec);
	}

	return dsi_ctx.accum_err;
}

#define ANA6706_FPS_120	(120)
#define ANA6706_FPS_60	(60)

/*
 * Four timings, exactly as the vendor DT lists them.
 *
 *   idx  size        fps  hfp hbp hpw  vfp  vbp  vpw  DSC slice  bpp
 *    0   1080x2376    60   64  48   8  1100 1100  188  540x72      8
 *    1   1080x2376   120   64  48   8     2    8    2  540x72      8
 *    2   1440x3168   120   88  56   8     8    8    8  720x96      8
 *    3   1440x3168    60   80  80   8   180  180   12  720x16     10
 *
 * idx 0's vfp/vbp of 1100/1100 is not a typo; it is the panel's long
 * blanking at 60 Hz. Do not "normalise" it -- that changes the refresh
 * rate the panel actually runs at.
 */
/*
 * NOTE ON .clock: it is the pixel clock in kHz, and msm uses it directly
 * -- dsi_host.c does `pclk_rate = mode->clock * 1000u`. An earlier revision
 * of this table carried hand-computed values that did not match their own
 * formula: the comment said 1200 * 2388 * 120 / 1000 but the value was
 * 155835, while that expression is 343872. msm therefore programmed the DSI
 * PLL for a pixel clock 2.2x too low, and the panel stayed black with no
 * error reported anywhere -- a wrong clock is not a failure the driver can
 * detect, only one the panel shows or does not.
 *
 * The values below are htotal * vtotal * fps / 1000, computed per mode.
 * dsi_get_pclk_rate() adjusts for DSC afterwards, so these stay the
 * uncompressed pixel clock.
 */
static const struct drm_display_mode ana6706_modes[] = {
	{ /* timing@0 */
		.clock = 343008,	/* 1200 * 4764 * 60 / 1000 */
		.hdisplay = 1080, .hsync_start = 1080 + 64,
		.hsync_end = 1080 + 64 + 8, .htotal = 1080 + 64 + 8 + 48,
		.vdisplay = 2376, .vsync_start = 2376 + 1100,
		.vsync_end = 2376 + 1100 + 188, .vtotal = 2376 + 1100 + 188 + 1100,
		.width_mm = 71, .height_mm = 157,
		.type = DRM_MODE_TYPE_DRIVER,
	},
	{ /* timing@1 -- the preferred one: 120 Hz at the phone's native logical size */
		.clock = 343872,	/* 1200 * 2388 * 120 / 1000 */
		.hdisplay = 1080, .hsync_start = 1080 + 64,
		.hsync_end = 1080 + 64 + 8, .htotal = 1080 + 64 + 8 + 48,
		.vdisplay = 2376, .vsync_start = 2376 + 2,
		.vsync_end = 2376 + 2 + 2, .vtotal = 2376 + 2 + 2 + 8,
		.width_mm = 71, .height_mm = 157,
		.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
	},
	/*
	 * timing@2 (1440x3168@120) and timing@3 (1440x3168@60) are NOT
	 * exposed.
	 *
	 * The panel is DSC and ana6706_dsc_cfg below has slice_width 540,
	 * which only divides 1080. Advertising the 1440-wide modes makes
	 * DRM pick one and then msm rejects it:
	 *
	 *   DSI: pic_width 1440 has to be multiple of slice 540
	 *
	 * (measured on this phone 2026-10-25). 1440 needs slice_width 720
	 * and slice_height 96 (or 16 for the 10bpp variant), i.e. a second
	 * DSC configuration selected together with the mode -- that is the
	 * runtime-timing-switch work this driver does not do yet.
	 *
	 * 1080x2376 is also the right size to expose: it is what Android
	 * reports as the logical display, and gamescope composits at it.
	 */
};

/*
 * DSC per timing index. Only the values that differ between the four
 * timings are here; the rest are common and set once in probe.
 *
 * NOTE: unused for now. ana6706_dsc_cfg hardcodes timing@1 (the preferred
 * 1080x2376@120). Switching timings at runtime needs drm_atomic hooks that
 * the DSC state is rebuilt per-mode; that is a follow-up, and until then
 * only timing@1 can actually be driven.
 *
 * slice_height is 72/72/96/16 and slice_width 540/540/720/720 -- these are
 * from the vendor DT's qcom,mdss-dsc-slice-* and they must match the
 * panel's own PPS or the picture is noise, so they are not generated.
 */
struct ana6706_dsc_timing {
	u16 slice_width;
	u16 slice_height;
	u8 bits_per_pixel;
};

static const struct ana6706_dsc_timing ana6706_dsc[] __maybe_unused = {
	{ 540, 72, 8 },
	{ 540, 72, 8 },
};

static int ana6706_get_modes(struct drm_panel *panel,
			     struct drm_connector *connector)
{
	struct ana6706 *ctx = to_ana6706(panel);
	struct drm_display_mode *mode;
	int i, count = 0;

	/*
	 * Verify every mode's .clock against its own geometry before handing
	 * it to DRM.
	 *
	 * .clock is the pixel clock in kHz and msm programs the DSI PLL
	 * straight from it, so a wrong value is a panel that never lights
	 * with no error anywhere -- msm writes the PLL successfully, the
	 * panel reports err_count 0, and nothing says "this clock is
	 * impossible". Four of the four modes in this table were wrong in an
	 * earlier revision, each by a different amount, because the values
	 * were typed in beside a formula instead of computed by it.
	 *
	 * One comparison here would have caught all four.
	 */
	for (i = 0; i < ARRAY_SIZE(ana6706_modes); i++) {
		const struct drm_display_mode *m = &ana6706_modes[i];
		unsigned long expect =
			(unsigned long)m->htotal * m->vtotal *
			drm_mode_vrefresh(m) / 1000;

		if (m->clock != expect)
			dev_warn(&ctx->dsi->dev,
				 "mode %dx%d@%d: .clock is %lu kHz but "
				 "htotal*vtotal*vrefresh is %lu kHz -- "
				 "the DSI PLL will be wrong\n",
				 m->hdisplay, m->vdisplay, drm_mode_vrefresh(m),
				 (unsigned long)m->clock, expect);
	}

	for (i = 0; i < ARRAY_SIZE(ana6706_modes); i++) {
		mode = drm_mode_duplicate(connector->dev, &ana6706_modes[i]);
		if (!mode)
			continue;
		drm_mode_set_name(mode);
		mode->type |= DRM_MODE_TYPE_DRIVER;
		connector->display_info.bpc = 8;
		drm_mode_probed_add(connector, mode);
		count++;
	}

	/*
	 * The panel is mounted portrait, with the long edge vertical. This
	 * is the value the panel driver reports and DRM turns the console
	 * with; the DTS rotation property is what feeds it, and Qualcomm's
	 * downstream convention is 180 degrees off from mainline's
	 * DRM_MODE_PANEL_ORIENTATION_*, which is why it cannot be taken
	 * from a vendor .dtsi verbatim (alioth paid for this: wrote <270>,
	 * got an upside-down console).
	 */
	connector->display_info.width_mm = 71;
	connector->display_info.height_mm = 157;

	return count;
}

static enum drm_panel_orientation
ana6706_get_orientation(struct drm_panel *panel)
{
	return DRM_MODE_PANEL_ORIENTATION_LEFT_UP;
}

static int ana6706_prepare(struct drm_panel *panel)
{
	struct ana6706 *ctx = to_ana6706(panel);
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(ana6706_supplies), ctx->supplies);
	if (ret) {
		dev_err(&ctx->dsi->dev, "failed to enable supplies: %d\n", ret);
		return ret;
	}

	/* PDPU: a short delay before releasing reset, vendor reset-sequence */
	usleep_range(1000, 2000);
	ana6706_reset(ctx);

	return 0;
}

/*
 * msm DSI host supports slice_per_pkt = 1 only (dsi_host.c has the TODO);
 * the vendor DT asks for 2. As on alioth, that difference is tolerated:
 * the panel's own PPS fixes slice_width 540 over a 1080 px line, so
 * slice_count stays 2 and the only consequence is one packet per line
 * instead of two.
 */
static struct drm_dsc_config ana6706_dsc_cfg = {
	.dsc_version_major = 1,
	.dsc_version_minor = 1,
	/*
	 * Decoded field-for-field from the panel's own PPS -- the 0x9e write
	 * at packet 21 of ana6706_init_sequence(). The panel programs its
	 * decoder from that command; the DPU programs its encoder from this
	 * structure. They describe the same encoder, so a field that
	 * disagrees makes the DPU emit a stream the panel decodes into
	 * noise.
	 *
	 * dsi_populate_dsc_params() (dsi_host.c) fills in the RC parameters
	 * msm can derive, but it computes from whatever geometry it is given
	 * -- it does not know this panel's PPS. These are the real values.
	 */
	.line_buf_depth = 9,
	.convert_rgb = true,
	.pic_width = 1080,
	.pic_height = 2376,
	.slice_width = 540,
	.slice_height = 72,
	.slice_count = 2,
	.slice_chunk_size = 540,
	.bits_per_component = 8,
	.bits_per_pixel = 8 << 4,
	.block_pred_enable = true,
	.initial_xmit_delay = 512,
	.initial_dec_delay = 594,
	.initial_scale_value = 32,
	.scale_increment_interval = 1595,
	.scale_decrement_interval = 7,
	.first_line_bpg_offset = 15,
	.nfl_bpg_offset = 433,
	.slice_bpg_offset = 362,
	.initial_offset = 6144,
	.final_offset = 4336,
	.flatness_min_qp = 3,
	.flatness_max_qp = 12,
	.rc_model_size = 8192,
	.rc_quant_incr_limit0 = 11,
	.rc_quant_incr_limit1 = 11,
	.rc_buf_thresh = {
		14, 28, 42, 56, 70, 84, 98, 105, 112, 119, 121, 123, 125, 126,
	},
	/*
	 * rc_edge_factor and rc_tgt_offset_* are deliberately absent:
	 * drm_dsc_pps_payload_pack() overwrites them with
	 * DSC_RC_EDGE_FACTOR_CONST / DSC_RC_TGT_OFFSET_*_CONST, so setting
	 * them here would be dead code that reads like a tuned parameter.
	 */
};

static int ana6706_enable(struct drm_panel *panel)
{
	struct ana6706 *ctx = to_ana6706(panel);
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct drm_dsc_picture_parameter_set pps;
	int ret;

	/*
	 * Iris analog-bypass status, read before anything else.
	 *
	 * The Pixelworks chip sits between the DSI host and the panel. The
	 * vendor driver brings it into analog bypass with
	 *
	 *     iris_send_ipopt_cmds(IRIS_IP_SYS, 0x8);
	 *     ... poll gpio until it reads 1 ...
	 *     iris_send_ipopt_cmds(IRIS_IP_SYS, 0x22);  // power domains off
	 *     iris_send_ipopt_cmds(IRIS_IP_SYS, 0x23);  // PLL off
	 *
	 * and treats this line being 1 as "data now passes through".
	 * mainline does none of that, so the value here says whether Iris
	 * happens to be transparent anyway (it may if the bootloader left it
	 * in bypass) or is still holding the link. That decides whether the
	 * remaining display work is about DSC packetisation or about
	 * implementing Iris bring-up.
	 */
	if (ctx->iris_abyp_ready_gpio)
		dev_info(&dsi->dev, "iris abyp-ready gpio = %d\n",
			 gpiod_get_value_cansleep(ctx->iris_abyp_ready_gpio));

	ret = ana6706_init_sequence(ctx);
	if (ret) {
		dev_err(&dsi->dev, "failed to init panel: %d\n", ret);
		return ret;
	}

	/*
	 * DSC PPS and compression mode, as their own DSI packets.
	 *
	 * The init sequence already writes a PPS into the panel through
	 * Qualcomm's private DCS 0x9e (packet 21 of the vendor sequence,
	 * sent as DTYPE_DCS_LWRITE 0x39). That alone is not enough, and the
	 * vendor kernel shows why: its mdss_dsi_panel_on() sends on_cmds and
	 * then calls mdss_dsi_panel_dsc_pps_send() separately, which emits a
	 * DTYPE_PPS (0x0a) packet in LP mode. That is a different packet
	 * type, not a repeat of the 0x9e write.
	 *
	 * mainline has no equivalent: drm_dsc_config only feeds the DPU
	 * encoder (dsi_populate_dsc_params), so the panel side is the driver's
	 * job. Without mipi_dsi_compression_mode(true) the DPU compresses
	 * and the panel never learns it should decompress -- which is a
	 * garbled picture, exactly what this port showed once the init
	 * sequence started running.
	 *
	 * Shape copied from panel-samsung-ams667xx01.c, the alioth panel that
	 * does light up on mainline.
	 */
	drm_dsc_pps_payload_pack(&pps, &ana6706_dsc_cfg);

	/*
	 * Neither of these is allowed to fail enable().
	 *
	 * The init sequence has already written the PPS into the panel via
	 * DCS 0x9e, so the panel's decoder is configured before this point.
	 * These two calls are the vendor's belt-and-braces repeat.
	 *
	 * Returning an error here is actively harmful: drm_panel_enable()
	 * failing makes DRM unwind the whole commit and call
	 * drm_panel_disable(), which sends 0x28 (display off) and 0x10
	 * (sleep in) -- the panel shows its one frame and then goes dark for
	 * good. That is exactly the "flashes once, then black forever"
	 * behaviour observed on hardware, and it started the moment the DSI
	 * readback began timing out (-110) at this point in enable().
	 *
	 * A failed repeat is worth a warning, not a dark screen.
	 */
	ret = mipi_dsi_picture_parameter_set(dsi, &pps);
	if (ret < 0)
		dev_warn(&dsi->dev, "PPS repeat failed: %d (0x9e already sent it)\n", ret);

	ret = mipi_dsi_compression_mode(dsi, true);
	if (ret < 0)
		dev_warn(&dsi->dev, "compression mode failed: %d\n", ret);

	/* 28 ms, panel-samsung-ams667xx01.c */
	msleep(28);

	/* 120 ms from vendor DT's qcom,mdss-dsi-init-delay-us */
	usleep_range(120000, 121000);

	dev_info(&dsi->dev, "enable() done\n");

	return 0;
}

static int ana6706_disable(struct drm_panel *panel)
{
	struct ana6706 *ctx = to_ana6706(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	/*
	 * Logged because this path is the prime suspect for the panel going
	 * dark right after it lights: the init sequence ends with
	 * power_mode = 0x98 (sleep-out set), and by the time enable() returns
	 * and the driver reads it back it is 0x0c (sleep-out clear). Nothing
	 * inside the sequence sends 0x10, so if this function runs between
	 * those two reads it is what put the panel back to sleep -- and a
	 * disable() straight after an enable() means DRM decided the commit
	 * failed, not that the panel did anything wrong.
	 */
	dev_info(&ctx->dsi->dev, "disable() called\n");

	mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	mipi_dsi_usleep_range(&dsi_ctx, 12000, 13000);
	mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);

	return 0;
}

static int ana6706_unprepare(struct drm_panel *panel)
{
	struct ana6706 *ctx = to_ana6706(panel);

	dev_info(&ctx->dsi->dev, "unprepare() called\n");

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	regulator_bulk_disable(ARRAY_SIZE(ana6706_supplies), ctx->supplies);

	return 0;
}

static const struct drm_panel_funcs ana6706_panel_funcs = {
	.prepare = ana6706_prepare,
	.enable = ana6706_enable,
	.disable = ana6706_disable,
	.unprepare = ana6706_unprepare,
	.get_modes = ana6706_get_modes,
	.get_orientation = ana6706_get_orientation,
};

/*
 * Backlight is DCS-brightness (vendor bl_ctrl_dcs, max 0x7ff).
 * drm_panel_bl_alloc() is the 7.2 API; the older
 * devm_backlight_device_register() path used by sofef00 no longer exists
 * on this tree (see patches/0017 for the same migration).
 */
static int ana6706_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	u16 brightness = backlight_get_brightness(bl);
	int ret;

	/*
	 * Run the brightness write with LPM off, as panel-samsung-amb655x.c
	 * and panel-samsung-ams667xx01.c both do. The panel's
	 * qcom,mdss-dsi-bl-max-level is 0x7ff, i.e. 11 bits, so this has to
	 * be the 16-bit ("large") DCS form rather than the 8-bit one.
	 */
	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;	/* high-speed for this write */
	ret = mipi_dsi_dcs_set_display_brightness_large(dsi, brightness);
	dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	if (ret < 0)
		return ret;

	return 0;
}

static const struct backlight_ops ana6706_bl_ops = {
	.update_status = ana6706_bl_update_status,
};

static struct backlight_device *ana6706_create_backlight(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = 0x7ff / 2,
		.max_brightness = 0x7ff,	/* vendor qcom,mdss-dsi-bl-max-level */
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &ana6706_bl_ops, &props);
}


static int ana6706_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct ana6706 *ctx;
	int ret;

	/* drm_panel_init() is gone in 7.2: this allocates and initialises. */
	ctx = devm_drm_panel_alloc(dev, struct ana6706, panel,
				   &ana6706_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ctx->supplies = devm_kcalloc(dev, ARRAY_SIZE(ana6706_supplies),
				     sizeof(*ctx->supplies), GFP_KERNEL);
	if (!ctx->supplies)
		return -ENOMEM;
	memcpy(ctx->supplies, ana6706_supplies, sizeof(ana6706_supplies));

	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(ana6706_supplies),
				      ctx->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "failed to get regulators\n");

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "failed to get reset gpio\n");

	/*
	 * Iris ABYP-ready is purely diagnostic here: it is an input, and its
	 * value answers whether the Pixelworks chip is transparent. Absent is
	 * fine -- the driver just will not report it.
	 */
	ctx->iris_abyp_ready_gpio = devm_gpiod_get_optional(dev, "iris-abyp-ready",
							    GPIOD_IN);
	if (IS_ERR(ctx->iris_abyp_ready_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->iris_abyp_ready_gpio),
				     "failed to get iris abyp-ready gpio\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->dsc = &ana6706_dsc_cfg;
	/*
	 * burst_mode + dsi_cmd_mode + DSC, straight from the vendor DT's
	 * qcom,mdss-dsi-traffic-mode / panel-type. NONCONTINUOUS_CLOCK
	 * matches the vendor's qcom,mdss-dsi-lp11-init behaviour.
	 */
	/*
	 * Command mode, so NO MIPI_DSI_MODE_VIDEO_* bit.
	 *
	 * The vendor DT says qcom,mdss-dsi-traffic-mode = "burst_mode", and
	 * an earlier revision of this driver translated that straight into
	 * MIPI_DSI_MODE_VIDEO_BURST. That is wrong: Qualcomm's "burst" is
	 * about how the DSI host packs a frame onto the link, while
	 * MIPI_DSI_MODE_VIDEO_BURST tells the host the panel is in *video*
	 * mode. For dsi_cmd_mode the host must not set it, or msm takes the
	 * video path and the panel's prepare/enable never runs the DCS
	 * sequence -- which is exactly what was observed: SETCRTC succeeded,
	 * the DSI TE interrupt kept firing at ~10 Hz, and the panel stayed
	 * dark because its init sequence had never been sent once.
	 *
	 * LPM because the vendor DT has qcom,mdss-dsi-lp11-init; NO_EOT
	 * because the panel does not expect an EOT packet after the last
	 * data lane, per the same DT's lane configuration.
	 */
	/*
	 * Video mode, matching the only DSC panel in this tree that actually
	 * lights up.
	 *
	 * panel-samsung-ams667xx01.c (the alioth panel, patches/0017) runs
	 * MIPI_DSI_MODE_VIDEO_BURST with DSC. This one had been left in
	 * command mode, and the vendor DT points the same way:
	 *
	 *     qcom,mdss-dsi-mdp-trigger = "none";
	 *     qcom,mdss-dsi-dma-trigger = "trigger_sw";
	 *
	 * meaning the vendor drives frames through the DSI controller's own
	 * command DMA, not through the MDP/DPU path. mainline's
	 * dsi_timing_setup() programs REG_DSI_CMD_MDP_STREAM0_* for command
	 * mode unconditionally, i.e. exactly the path the vendor switched
	 * off. So command mode here means: panel says display-on, DSI reports
	 * no errors, frames are consumed -- and nothing appears.
	 *
	 * An earlier attempt at video mode was abandoned because the init
	 * sequence stopped running with it. That measurement was taken while
	 * the reset line was still being left asserted by a GPIO_ACTIVE_LOW
	 * polarity bug, so it proved nothing about video mode itself. With
	 * reset, compression mode and slice_per_pkt now fixed, it gets a fair
	 * test.
	 */
	dsi->mode_flags = MIPI_DSI_MODE_VIDEO_BURST |
			  MIPI_DSI_MODE_LPM |
			  MIPI_DSI_MODE_NO_EOT_PACKET;

	ctx->panel.prepare_prev_first = true;

	ctx->panel.backlight = ana6706_create_backlight(dsi);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),
				     "failed to create backlight\n");

	drm_panel_add(&ctx->panel);

	ret = mipi_dsi_attach(dsi);
	if (ret) {
		drm_panel_remove(&ctx->panel);
		return dev_err_probe(dev, ret, "failed to attach dsi\n");
	}

	return 0;
}

static void ana6706_remove(struct mipi_dsi_device *dsi)
{
	struct ana6706 *ctx = mipi_dsi_get_drvdata(dsi);

	mipi_dsi_detach(dsi);
	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id ana6706_of_match[] = {
	{ .compatible = "oneplus,ana6706" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ana6706_of_match);

static struct mipi_dsi_driver ana6706_driver = {
	.probe = ana6706_probe,
	.remove = ana6706_remove,
	.driver = {
		.name = "panel-oneplus-ana6706",
		.of_match_table = ana6706_of_match,
	},
};
module_mipi_dsi_driver(ana6706_driver);

MODULE_AUTHOR("SteamOS for alioth port");
MODULE_DESCRIPTION("Samsung ANA6706 1440x3168 DSC command mode panel (OnePlus 8 Pro)");
MODULE_LICENSE("GPL");