APP_NAME = ScreenInset
BUILD_DIR = .build
SOURCES = Sources/ScreenInset/*.swift
SWIFTC = swiftc
SWIFT_FLAGS = -O -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -framework CoreGraphics
INSTALL_DIR = ~/Applications
PLIST_DIR = ~/Library/LaunchAgents

all: build

build:
	mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) -o $(BUILD_DIR)/$(APP_NAME) $(SOURCES)
	codesign -s - $(BUILD_DIR)/$(APP_NAME)

run: build
	./$(BUILD_DIR)/$(APP_NAME)

install: build
	mkdir -p $(INSTALL_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(INSTALL_DIR)/$(APP_NAME)
	mkdir -p $(PLIST_DIR)
	cp com.user.screeninset.plist $(PLIST_DIR)/
	launchctl unload $(PLIST_DIR)/com.user.screeninset.plist 2>/dev/null || true
	launchctl load $(PLIST_DIR)/com.user.screeninset.plist

clean:
	rm -rf $(BUILD_DIR)
