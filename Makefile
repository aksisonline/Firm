APP      = TrackpadPen
BUILD    = .build/release
BUNDLE   = build/$(APP).app
CONTENTS = $(BUNDLE)/Contents

.PHONY: all build bundle run clean

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD)/$(APP) $(CONTENTS)/MacOS/$(APP)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	codesign --force --sign - --identifier dev.aksisonline.TrackpadPen $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build build
