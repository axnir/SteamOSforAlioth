FROM fedora:43
# 工具链镜像：把 scripts/op8p-build-container.sh 每次都要装的 330 个包烧进
# 镜像层，让增量构建从"重下依赖 + 重链"缩到只剩重链。
#
# 它只影响**速度**，不影响正确性：容器内脚本仍然会 dnf install 一遍（幂等），
# 所以镜像过期、包被仓库更新时，构建会自己补齐，不会用一份旧工具链悄悄编译。
#
# 构建：
#   docker build -t op8p-build:43 -f scripts/op8p-build.Dockerfile .
# scripts/op8p-build-docker.sh 会在第一次运行时自动做这件事。
#
# 包列表必须与容器内脚本一致（那边是权威，因为它在没有这张镜像时也要能跑）。
RUN rm -f /etc/yum.repos.d/*.repo \
 && printf '[fedora]\nname=Fedora $releasever - $basearch\nbaseurl=https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/$releasever/Everything/$basearch/os/\nenabled=1\ngpgcheck=0\nskip_if_unavailable=1\n\n[updates]\nname=Fedora $releasever - $basearch - Updates\nbaseurl=https://mirrors.tuna.tsinghua.edu.cn/fedora/updates/$releasever/Everything/$basearch/\nenabled=1\ngpgcheck=0\nskip_if_unavailable=1\n' \
      > /etc/yum.repos.d/fedora-build.repo \
 && dnf -q -y --setopt=install_weak_deps=False install \
      file gcc binutils make bc bison flex python3 curl tar xz gzip zstd cpio \
      kmod patch perl rsync openssl-devel elfutils-libelf-devel dwarves \
      diffutils findutils hostname which git dtc \
      e2fsprogs squashfs-tools btrfs-progs util-linux \
 && dnf clean all && rm -rf /var/cache/dnf/*
# dtc：宿主机上的 assert-op8p-stage2.sh 用它在编完之后反编译 dtb，确认节点
# 真的进了产物；在容器里手查也方便。
#
# e2fsprogs + squashfs-tools + btrfs-progs：不是内核构建要的，是
# make-op8p.sh --install / --verify 要的 —— mkfs.ext4 -d、unsquashfs
# （拆 RAUC bundle）、e2fsck、以及 btrfs restore（Valve 的 rootfs.img 是
# btrfs，而容器没有 CAP_SYS_ADMIN，loop 挂载必然失败，只能离线恢复）。
# util-linux 给 mountpoint/blkid。放在同一个镜像里是为了只有一份工具链要维护。
