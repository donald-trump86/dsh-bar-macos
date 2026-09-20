.PHONY: all build install clean run

all: build

build:
	@chmod +x build.sh
	@./build.sh

install:
	@chmod +x build.sh
	@./build.sh install

run: install
	@open -a "DSH Bar"

clean:
	@rm -rf build
	@echo "Cleaned build artifacts."
