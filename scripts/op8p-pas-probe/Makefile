# 一次性 PAS 探测模块。在内核源码树里编译：
#   make -C <内核源码目录> M="$(pwd)" modules
obj-m += op8p-pas-probe.o

# 从本机内核头文件取 qcom_scm API 原型，不在这里重复声明。
# 若编译报 struct qcom_scm_pas_metadata / qcom_scm_pas_ctx 类型不匹配，
# 按本机 <linux/firmware/qcom/qcom_scm.h> 把 .c 里的 meta 声明改成对应类型。
