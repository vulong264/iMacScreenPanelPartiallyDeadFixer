APP_NAME = ScreenInset
BUILD_DIR = .build
SOURCES = Sources/ScreenInset/*.swift
SWIFTC = swiftc
SWIFT_FLAGS = -O -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -framework CoreGraphics
INSTALL_DIR ?= $(HOME)/Applications
PLIST_DIR ?= $(HOME)/Library/LaunchAgents

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
	codesign -f -s - $(INSTALL_DIR)/$(APP_NAME)
	mkdir -p $(PLIST_DIR)
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(PLIST_DIR)/com.user.screeninset.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '<plist version="1.0">' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '<dict>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <key>Label</key>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <string>com.user.screeninset</string>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <key>ProgramArguments</key>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <array>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '        <string>$(INSTALL_DIR)/$(APP_NAME)</string>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    </array>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <key>RunAtLoad</key>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <true/>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <key>ProcessType</key>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '    <string>Interactive</string>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '</dict>' >> $(PLIST_DIR)/com.user.screeninset.plist
	@echo '</plist>' >> $(PLIST_DIR)/com.user.screeninset.plist
	launchctl unload $(PLIST_DIR)/com.user.screeninset.plist 2>/dev/null || true
	launchctl load $(PLIST_DIR)/com.user.screeninset.plist

clean:
	rm -rf $(BUILD_DIR)
