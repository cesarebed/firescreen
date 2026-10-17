# FireScreen: Mac sender + Fire TV receiver. Run `make help`.

APP := sender/FireScreen.app
BIN := $(APP)/Contents/MacOS/FireScreen
APK := receiver/build/firescreen-receiver.apk

.PHONY: help all receiver app install install-receiver test test-sender test-receiver clips clean

help:
	@echo "make all                    build the receiver APK and FireScreen.app (with the APK inside)"
	@echo "make receiver               build the Fire TV receiver APK"
	@echo "make app                    build sender/FireScreen.app"
	@echo "make install                copy FireScreen.app to /Applications"
	@echo "make install-receiver HOST=192.168.1.20   install the receiver on a Fire TV over adb"
	@echo "make test                   self-tests for sender and receiver (no devices needed)"
	@echo "make clips DIR=~/Movies     write the sync and motion test videos"
	@echo "make clean                  remove build outputs"

all: receiver app

receiver:
	receiver/build.sh

app:
	sender/make-app.sh

install: app
	rm -rf /Applications/FireScreen.app
	cp -R $(APP) /Applications/
	@echo "Installed. Open FireScreen from /Applications; it lives in the menu bar."

install-receiver: receiver
	@test -n "$(HOST)" || (echo "usage: make install-receiver HOST=<Fire TV IP>" && exit 1)
	$(BIN) install-receiver $(HOST) --apk $(APK) || swift run --package-path sender -c release FireScreen install-receiver $(HOST) --apk $(APK)

test: test-sender test-receiver

test-sender:
	swift run --package-path sender -c release FireScreenSelfTest

test-receiver:
	receiver/test.sh

clips:
	@test -n "$(DIR)" || (echo "usage: make clips DIR=<folder>" && exit 1)
	swift run --package-path sender -c release FireScreen make-test-clips $(DIR)

clean:
	rm -rf sender/.build $(APP) receiver/build
