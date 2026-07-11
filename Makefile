prj=PingPlaceEx.app
all: build

build:
	@mkdir -p ${prj}/Contents/MacOS
	@mkdir -p ${prj}/Contents/Resources
	@cp src/Info.plist ${prj}/Contents/
	@cp src/assets/app-icon/icon.icns ${prj}/Contents/Resources/
	@cp src/assets/menu-bar-icon/MenuBarIcon*.png ${prj}/Contents/Resources/
	swiftc src/PingPlace.swift -o ${prj}/Contents/MacOS/PingPlace-x86_64 -O -target x86_64-apple-macos14.0
	swiftc src/PingPlace.swift -o ${prj}/Contents/MacOS/PingPlace-arm64 -O -target arm64-apple-macos14.0
	lipo -create -output ${prj}/Contents/MacOS/PingPlace ${prj}/Contents/MacOS/PingPlace-x86_64 ${prj}/Contents/MacOS/PingPlace-arm64
	rm ${prj}/Contents/MacOS/PingPlace-x86_64 ${prj}/Contents/MacOS/PingPlace-arm64
	# 用稳定的自签名证书 "PingPlace" 签名：签名身份固定，重建不会丢失辅助功能(TCC)授权。
	# （ad-hoc "-" 每次重建 CDHash 都变，系统当成新 App，导致反复要权限。）
	# 证书需为「代码签名」类型，存于登录或系统钥匙串；可用 `codesign -s "PingPlace"` 验证。
	#codesign --force -s "PingPlace" ${prj}

run:
	@open ${prj}

clean:
	@rm -rf ${prj} ${prj}.tar.gz

publish:
	@tar --uid=0 --gid=0 -czf ${prj}.tar.gz ${prj}
	@shasum -a 256 ${prj}.tar.gz | cut -d ' ' -f 1
	@echo "don't forget to change the version number"
