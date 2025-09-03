#!/usr/bin/env bash
# shellcheck disable=SC2199
# shellcheck source=/dev/null

# Copyright (C) 2024 Your Name <your-email@example.com>
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0

# -------------------------- 1. 配置本地工具链与环境变量 --------------------------
# 本地LLVM工具链路径（你的指定路径）
LOCAL_LLVM_DIR="/opt/LLVM-21.1.0-Linux-ARM64/bin"
# 检查工具链是否存在（避免编译前报错）
if ! [ -d "${LOCAL_LLVM_DIR}" ]; then
    echo "错误：本地工具链目录不存在！路径：${LOCAL_LLVM_DIR}"
    exit 1
fi

# 配置环境变量（整合你的参数，优先使用本地工具链）
export PATH="${LOCAL_LLVM_DIR}:/usr/bin:$PATH"
export ARCH="arm64"
export SUBARCH="arm64"
export CC="clang"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
export TRIPLE="aarch64-linux-gnu-"
# 配置编译器/链接器信息（供内核识别）
export KBUILD_COMPILER_STRING="$(${CC} --version | head -n 1 | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
export KBUILD_LINKER_STRING="$(${LOCAL_LLVM_DIR}/ld.lld --version | head -n 1 | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"

# -------------------------- 2. 设备与配置文件匹配（已修正为milito_defconfig） --------------------------
# 脚本第一个参数为设备型号（如：./build.sh milito），默认匹配milito_defconfig
DEVICE="$1"
if [ -z "${DEVICE}" ]; then
    echo "用法：./build.sh [设备型号]"
    echo "当前默认设备：milito（对应配置文件：arch/arm64/configs/milito_defconfig）"
    exit 1
fi

# 关键修正：指定配置文件为 milito_defconfig（无需额外设备判断，直接匹配）
DEFCONFIG="milito_defconfig"
echo "当前使用配置文件：arch/arm64/configs/${DEFCONFIG}"

# -------------------------- 3. 编译核心参数配置 --------------------------
# 内核源码目录（你的小米SM7250内核路径，已修正/hone为/home）
KERNEL_SRC_DIR="/home/ya/kernel_xiaomi_sm7250_a16bpf"
# 编译输出目录
OUT_DIR="${KERNEL_SRC_DIR}/out"
# 版本命名（包含设备、时间，便于区分）
DATE=$(date '+%Y%m%d-%H%M')
VERSION="Skizo-ksu-${DEVICE}-${DATE}"
# 最终ZIP刷机包名
export ZIPNAME="${VERSION}.zip"
# 编译线程数（使用全部CPU核心）
export KEBABS=$(nproc --all)

# 编译参数（整合O=out、LLVM等配置）
ARGS="O=${OUT_DIR} \
LLVM=1 \
LLVM_IAS=1 \
CLANG_TRIPLE=${TRIPLE} \
-j${KEBABS}"

# -------------------------- 4. 开始编译流程 --------------------------
echo -e "\n====== 编译信息 ======"
echo "设备：${DEVICE}"
echo "Defconfig：${DEFCONFIG}"
echo "工具链：${LOCAL_LLVM_DIR}"
echo "内核源码目录：${KERNEL_SRC_DIR}"
echo "输出目录：${OUT_DIR}"
echo "编译线程：${KEBABS}"
echo "======================"

# 进入内核源码目录（避免路径错误）
cd "${KERNEL_SRC_DIR}" || { echo "错误：无法进入内核目录 ${KERNEL_SRC_DIR}"; exit 1; }

# 记录编译开始时间
START=$(date +"%s")

# 1. 生成初始defconfig（使用修正后的milito_defconfig）
echo -e "\n------ 生成初始配置 ${DEFCONFIG} ------"
make ${ARGS} ${DEFCONFIG}
if [ $? -ne 0 ]; then echo "错误：生成defconfig失败"; exit 1; fi

# 2. 补全配置（自动处理未定义选项）
echo -e "\n------ 补全配置（olddefconfig） ------"
make ${ARGS} olddefconfig
if [ $? -ne 0 ]; then echo "错误：补全配置失败"; exit 1; fi

# 3. 执行内核编译（输出日志到build.log）
echo -e "\n------ 开始编译（日志：${KERNEL_SRC_DIR}/build.log） ------"
make ${ARGS} CC="ccache clang" HOSTCC="ccache gcc" HOSTCXX="ccache g++" 2>&1 | tee build.log
if [ $? -ne 0 ]; then echo "错误：内核编译失败，查看build.log获取详情"; exit 1; fi

# 4. 合并设备树（DTB，Android内核启动必需）
echo -e "\n------ 合并设备树（DTB） ------"
DTS_SOURCE="${OUT_DIR}/arch/arm64/boot/dts/vendor/qcom"
find "${DTS_SOURCE}" -name '*.dtb' -exec cat {} + >"${OUT_DIR}/arch/arm64/boot/dtb"
if [ $? -ne 0 ]; then echo "错误：合并DTB失败"; exit 1; fi

# 恢复设备树源码（避免编译修改影响git仓库）
git checkout arch/arm64/boot/dts/vendor &>/dev/null

# -------------------------- 5. 生成ZIP刷机包 --------------------------
echo -e "\n------ 检查编译产物并生成ZIP ------"
# 检查核心产物是否存在（Image=内核镜像，dtb=设备树）
if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ] && [ -f "${OUT_DIR}/arch/arm64/boot/dtb" ]; then
    # 克隆AnyKernel3（内核打包工具，若设备分支不存在，需替换为实际分支如main）
    git clone -q https://github.com/alecchangod/AnyKernel3.git -b ${DEVICE}
    # 复制编译产物到AnyKernel3目录
    cp "${OUT_DIR}/arch/arm64/boot/Image" AnyKernel3/
    cp "${OUT_DIR}/arch/arm64/boot/dtb" AnyKernel3/
    # 打包ZIP（排除git和冗余文件）
    cd AnyKernel3 || exit 1
    zip -r9 "../${ZIPNAME}" * -x '*.git*' README.md *placeholder >>/dev/null
    cd .. || exit 1
    # 清理临时目录
    rm -rf AnyKernel3

    # 计算编译耗时
    END=$(date +"%s")
    DIFF=$((END - START))
    echo -e "\n✅ 编译完成！耗时：$((DIFF / 60)) 分 $((DIFF % 60)) 秒"
    echo "✅ 刷机包路径：${KERNEL_SRC_DIR}/${ZIPNAME}"
else
    echo -e "\n❌ 编译失败！缺少核心产物（Image或dtb）"
    exit 1
fi

