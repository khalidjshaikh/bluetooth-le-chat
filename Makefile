APP_NAME := BLEChat
CONFIG   := release
BUNDLE   := $(APP_NAME).app
BINARY   := .build/$(CONFIG)/$(APP_NAME)

.PHONY: build app run clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE) >/dev/null 2>&1 || true
	@echo "Built $(BUNDLE)"

run: app
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf $(BUNDLE)
