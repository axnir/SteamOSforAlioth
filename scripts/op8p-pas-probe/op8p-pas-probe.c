// SPDX-License-Identifier: GPL-2.0-only
/*
 * op8p-pas-probe.c —— 一次性探测高通 PAS SCM 调用，定位 -22 的真实阶段。
 *
 * 背景：Galaxy Tab S6（SM8150）上逐字相同的 "error -22 setting up firmware"
 * 真因是 qcom_scm_pas_mem_setup() 拒绝内存区，而不是固件签名。本机 System.map
 * 确认下面几个函数都是 EXPORT_SYMBOL_GPL，因此可以用模块直接调用、逐段打印返回码：
 *
 *   qcom_scm_pas_init_image()       固件准备 / TZ 验签
 *   qcom_scm_pas_mem_setup()        内存区放置（Tab S6 的 -22 真因在这一步）
 *   qcom_scm_pas_auth_and_reset()   TZ 启动 DSP（默认关闭）
 *
 * 默认只做 mem_setup：不需要固件、不会启动 DSP、最安全。
 * do_init=1 会验签；do_auth=1 会真正启动 DSP，有风险，默认关闭。
 *
 * 本机内核（7.2.8-sm8250）的 init_image 第 4 参数是 struct qcom_scm_pas_context *，
 * 只能由 devm_qcom_scm_pas_context_alloc() 分配，该函数需要一个 device。
 * 这里注册一个空的 platform device 作为载体；ctx 一律用 void * 传递，
 * 避免模块重复声明随内核版本变化的结构体。
 *
 * 模块 init 故意返回 -EAGAIN —— insmod 会打印 "Invalid argument" 并退出失败，
 * 这是预期行为：调用已经执行完，模块不会驻留。结果只看 dmesg。
 *
 * 用法（设备上 root）：
 *   insmod /tmp/op8p-pas-probe.ko pas_id=1 addr=0x8a100000 size=0x1d00000
 *   insmod /tmp/op8p-pas-probe.ko do_init=1 fw_name=postmarketos/adsp.mbn
 *   insmod /tmp/op8p-pas-probe.ko do_init=1 do_auth=1     # 危险：真启动 DSP
 */

#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/err.h>
#include <linux/firmware.h>
#include <linux/platform_device.h>
#include <linux/soc/qcom/mdt_loader.h>

#if __has_include(<linux/firmware/qcom/qcom_scm.h>)
#include <linux/firmware/qcom/qcom_scm.h>
#else
#include <linux/qcom_scm.h>
#endif

static char *fw_name = "postmarketos/adsp.mbn";
module_param(fw_name, charp, 0644);
MODULE_PARM_DESC(fw_name, "固件名，相对 /lib/firmware/；仅 do_init=1 时用到");

static unsigned int pas_id = 1;
module_param(pas_id, uint, 0644);
MODULE_PARM_DESC(pas_id, "PAS 子系统 ID（ADSP=1，CDSP 请按 DTS/驱动确认）");

static unsigned long probe_addr = 0x8a100000UL;
module_param_named(addr, probe_addr, ulong, 0644);
MODULE_PARM_DESC(addr, "qcom_scm_pas_mem_setup 的物理地址");

static unsigned long probe_size = 0x1d00000UL;
module_param_named(size, probe_size, ulong, 0644);
MODULE_PARM_DESC(size, "qcom_scm_pas_mem_setup 的大小（建议传固件 ELF LOAD span）");

static bool do_init;
module_param(do_init, bool, 0644);
MODULE_PARM_DESC(do_init, "是否先调用 qcom_scm_pas_init_image() 做验签");

static bool do_auth;
module_param(do_auth, bool, 0644);
MODULE_PARM_DESC(do_auth, "是否调用 qcom_scm_pas_auth_and_reset()（危险，默认关）");

static bool pre_shutdown = true;
module_param(pre_shutdown, bool, 0644);
MODULE_PARM_DESC(pre_shutdown, "调用前先 pas_shutdown 清理残留 PAS 状态");

static bool post_shutdown = true;
module_param(post_shutdown, bool, 0644);
MODULE_PARM_DESC(post_shutdown, "结束后 pas_shutdown，避免污染 remoteproc");

static int __init pas_probe_init(void)
{
	struct platform_device *pdev = NULL;
	const struct firmware *fw = NULL;
	void *metadata = NULL;
	size_t metadata_len = 0;
	void *ctx = NULL;
	int ret;

	pr_info("pas_probe: BEGIN pas_id=%u addr=0x%lx size=0x%lx init=%d auth=%d\n",
		pas_id, probe_addr, probe_size, do_init, do_auth);

	if (pre_shutdown) {
		ret = qcom_scm_pas_shutdown(pas_id);
		pr_info("pas_probe: pre_shutdown(%u) = %d (ignored)\n", pas_id, ret);
	}

	if (do_init) {
		pdev = platform_device_register_simple("pas-probe", -1, NULL, 0);
		if (IS_ERR(pdev)) {
			pr_err("pas_probe: platform_device_register_simple = %ld\n",
			       PTR_ERR(pdev));
			pdev = NULL;
			goto out;
		}

		ctx = devm_qcom_scm_pas_context_alloc(&pdev->dev, pas_id,
						      (phys_addr_t)probe_addr,
						      (size_t)probe_size);
		if (IS_ERR(ctx)) {
			pr_err("pas_probe: pas_context_alloc = %ld\n", PTR_ERR(ctx));
			ctx = NULL;
			goto out_pdev;
		}

		/* 本内核 firmware_loader 会 dev_dbg(device, ...)，不能传 NULL。 */
		ret = request_firmware_direct(&fw, fw_name, &pdev->dev);
		if (ret) {
			pr_err("pas_probe: request_firmware_direct(%s) = %d\n",
			       fw_name, ret);
			goto out_ctx;
		}

		/* 驱动真实路径传的是 ELF 头 + hash 段组成的 metadata，
		 * 不是整份 mbn（整份传给 TZ 必然 -EINVAL）。 */
		metadata = qcom_mdt_read_metadata(fw, &metadata_len, fw_name,
						  &pdev->dev);
		if (IS_ERR(metadata)) {
			ret = PTR_ERR(metadata);
			pr_err("pas_probe: qcom_mdt_read_metadata(%s) = %d\n",
			       fw_name, ret);
			metadata = NULL;
			goto out_fw;
		}
		pr_info("pas_probe: metadata_len=%zu (fw_size=%zu)\n",
			metadata_len, fw->size);

		ret = qcom_scm_pas_init_image(pas_id, metadata, metadata_len, ctx);
		pr_info("pas_probe: init_image(pas=%u, mdata=%zu) = %d\n",
			pas_id, metadata_len, ret);
		if (ret)
			goto out_meta;
	}

	ret = qcom_scm_pas_mem_setup(pas_id, (phys_addr_t)probe_addr,
				     (size_t)probe_size);
	pr_info("pas_probe: mem_setup(pas=%u, addr=0x%lx, size=0x%lx) = %d\n",
		pas_id, probe_addr, probe_size, ret);

	if (do_auth) {
		ret = qcom_scm_pas_auth_and_reset(pas_id);
		pr_info("pas_probe: auth_and_reset(%u) = %d\n", pas_id, ret);
	}

out_meta:
	kfree(metadata);
out_fw:
	if (fw)
		release_firmware(fw);
out_ctx:
	if (ctx)
		qcom_scm_pas_metadata_release(ctx);
out_pdev:
	if (pdev)
		platform_device_unregister(pdev);
out:
	if (post_shutdown) {
		ret = qcom_scm_pas_shutdown(pas_id);
		pr_info("pas_probe: post_shutdown(%u) = %d\n", pas_id, ret);
	}
	pr_info("pas_probe: END (returning -EAGAIN on purpose)\n");

	return -EAGAIN;
}

static void __exit pas_probe_exit(void)
{
	/* init 返回 -EAGAIN，这里永远不会被调用 */
}

module_init(pas_probe_init);
module_exit(pas_probe_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("One-off PAS SCM probe for Qualcomm remoteproc -22 diagnosis");
