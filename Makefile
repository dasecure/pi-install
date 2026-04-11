APP_NAME    := pi-agent
VERSION     := 3.1.4
BUILD_DIR   := build
LDFLAGS     := -s -w -X main.version=$(VERSION)

# Cross-compilation targets
TARGETS := \
	$(BUILD_DIR)/linux-arm64/$(APP_NAME) \
	$(BUILD_DIR)/linux-amd64/$(APP_NAME) \
	$(BUILD_DIR)/darwin-arm64/$(APP_NAME) \
	$(BUILD_DIR)/darwin-amd64/$(APP_NAME) \
	$(BUILD_DIR)/windows-amd64/$(APP_NAME).exe

.PHONY: all build clean $(TARGETS) tidy

all: $(TARGETS)

$(BUILD_DIR)/linux-arm64/$(APP_NAME):
	GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $@ .

$(BUILD_DIR)/linux-amd64/$(APP_NAME):
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o $@ .

$(BUILD_DIR)/darwin-arm64/$(APP_NAME):
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $@ .

$(BUILD_DIR)/darwin-amd64/$(APP_NAME):
	GOOS=darwin GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o $@ .

$(BUILD_DIR)/windows-amd64/$(APP_NAME).exe:
	GOOS=windows GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o $@ .

build:
	go build -ldflags "$(LDFLAGS)" -o $(BUILD_DIR)/$(APP_NAME) .

clean:
	rm -rf $(BUILD_DIR)

tidy:
	go mod tidy
