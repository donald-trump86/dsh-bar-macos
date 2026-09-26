.PHONY: all build install clean run check

all: build

build:
	@chmod +x build.sh
	@./build.sh

install:
	@chmod +x build.sh
	@./build.sh install

run: install
	@open -a "DeepSeek Harness Bar"

check:
	@./Tests/run-checks.sh

clean:
	@rm -rf build
	@echo "Cleaned build artifacts."
