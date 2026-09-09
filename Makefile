.PHONY: all build bundle run install test dmg clean

all: bundle

build:
	swift build -c release

bundle:
	Scripts/build.sh

run:
	Scripts/build.sh --run

install:
	Scripts/build.sh --install

test:
	swift test

dmg:
	Scripts/make-dmg.sh

clean:
	rm -rf .build build
