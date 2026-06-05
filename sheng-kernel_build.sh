#!/bin/bash
set -e

# ==========================================
# 1. 编译缓存 (ccache) 与 LLVM 工具链配置
# ==========================================
if [ -z "$CCACHE_DIR" ]; then
	export CCACHE_DIR="/home/runner/.ccache"
	export CCACHE_MAXSIZE="10G"
	export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

mkdir -p "$CCACHE_DIR"

export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

# ==========================================
# 2. 拉取内核源码 (默认使用 sheng-mainline 分支)
# ==========================================
# 如果你想换回 sheng-7.0 分支，直接修改下面这行的 --branch 参数即可
git clone https://github.com/code002-2/sm8550-mainline.git --branch sheng-mainline --depth 1 linux
cd linux

# ==========================================
# 3. 智能定位并应用内核配置文件 (.config)
# ==========================================
echo "⚙️ 正在智能定位并配置内核..."
CONFIG_PATH=$(find "$GITHUB_WORKSPACE" ../ -maxdepth 2 -name "config*.aarch64" 2>/dev/null | head -n 1)

if [ -n "$CONFIG_PATH" ]; then
	echo "✅ 成功找到并复制配置文件: $CONFIG_PATH"
	cp "$CONFIG_PATH" .config
else
	echo "⚠️ 未找到动态配置文件，尝试使用后备默认配置..."
	cp ../config-postmarketos-qcom-sm8550.aarch64 .config || {
		echo "❌ 致命错误: 找不到任何配置文件！"
		exit 1
	}
fi

# ==========================================
# 4. 极速编译内核
# ==========================================
echo "🔨 开始使用 LLVM Clang 编译内核..."
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1
_kernel_version="$(make kernelrelease -s)"

# 更新 DEBIAN/control 中的版本号
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-sheng/DEBIAN/control

# ==========================================
# 5. 提取产物并注入打包目录
# ==========================================
PKGDIR=../linux-xiaomi-sheng
ARCH=arm64

mkdir -p $PKGDIR/boot

install -Dm644 arch/$ARCH/boot/Image.gz \
	$PKGDIR/boot/Image.gz

install -Dm644 arch/$ARCH/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
	$PKGDIR/boot/sm8550-xiaomi-sheng.dtb

install -Dm644 .config \
	$PKGDIR/boot/config-${_kernel_version}

install -Dm644 System.map \
	$PKGDIR/boot/System.map-${_kernel_version}

chmod +x ../mkbootimg

# ==========================================
# 6. 打包 Android 规范的 boot.img (包含全局防黑屏补丁与 A 槽位硬编码)
# ==========================================
# 将 Image.gz 和设备树 (DTB) 拼接到一起
cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb >Image.gz-dtb_sheng

install -Dm644 Image.gz-dtb_sheng \
	$PKGDIR/boot/Image.gz-dtb_sheng

mv Image.gz-dtb_sheng zImage_sheng

# 🚨 核心神级修复：在此处成功向 --cmdline 追加 slot_suffix=_b androidboot.slot_suffix=b
# 确保系统能够明确得知自己运行在 B 槽位，彻底为 qbootctl 铺平道路
../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=linux rootwait rw slot_suffix=_b androidboot.slot_suffix=b" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_dualboot.img
../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=userdata rootwait rw slot_suffix=_b androidboot.slot_suffix=b" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_singleboot.img

# ==========================================
# 7. 编译内核模块并清理冗余链接 (减小 deb 包体积)
# ==========================================
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../linux-xiaomi-sheng modules_install

echo "🧹 正在清理冗余的 build 和 source 软链接..."
rm -rf ../linux-xiaomi-sheng/lib/modules/*/build || true
rm -rf ../linux-xiaomi-sheng/lib/modules/*/source || true

cd ..

# ==========================================
# 8. 打包各种外设固件 (Wi-Fi, 蓝牙, 触屏等)
# ==========================================
echo "📦 正在拉取并构建固件与音频补丁包..."

# 高通固件
git clone https://github.com/map220v/sheng-firmware
mkdir -p firmware-xiaomi-sheng/usr/lib/firmware
cp -r sheng-firmware/* firmware-xiaomi-sheng/usr/lib/firmware/

# 音频驱动 (ALSA)
git clone https://github.com/alghiffaryfa19/alsa-sheng
cp -r alsa-sheng/* alsa-xiaomi-sheng/

# 最终生成所有的 Debian 包
dpkg-deb --build --root-owner-group linux-xiaomi-sheng
dpkg-deb --build --root-owner-group firmware-xiaomi-sheng
dpkg-deb --build --root-owner-group alsa-xiaomi-sheng
dpkg-deb --build --root-owner-group sheng-devauth

echo "🎉 终极通用版内核与驱动打包圆满完成！"
