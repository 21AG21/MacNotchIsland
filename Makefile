.PHONY: all build bundle run install clean

all: bundle

build:
	swift build -c release

bundle:
	Scripts/build.sh

run:
	Scripts/build.sh --run

install:
	Scripts/build.sh --install

clean:
	rm -rf .build build
