project := "OpenDisk.xcodeproj"
scheme := "OpenDisk"
derived_data := "build/DerivedData"
app_name := "OpenDisk.app"
install_dir := "/Applications"

# Xcode names Apple Silicon "arm64", while just reports it as "aarch64".
xcode_arch := if arch() == "aarch64" { "arm64" } else { "x86_64" }

# Ad-hoc signing, so building does not require the upstream team's certificates.
signing := "CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER="

xcodebuild := "xcodebuild -project " + project + " -scheme " + scheme + " -derivedDataPath " + derived_data + " -destination 'platform=macOS,arch=" + xcode_arch + "' ARCHS=" + xcode_arch + " " + signing

# List available commands
default:
    @just --list

# Build debug version of the app
build:
    {{xcodebuild}} -configuration Debug build

# Build desktop version of the app (Release)
build-desktop:
    {{xcodebuild}} -configuration Release build
    @echo "Built: {{derived_data}}/Build/Products/Release/{{app_name}}"

# Run unit tests
test:
    {{xcodebuild}} -only-testing:OpenDiskTests test

# Build and launch debug version of the app
run: build
    open "{{derived_data}}/Build/Products/Debug/{{app_name}}"

# Install desktop version into /Applications
install: build-desktop
    rm -rf "{{install_dir}}/{{app_name}}"
    ditto "{{derived_data}}/Build/Products/Release/{{app_name}}" "{{install_dir}}/{{app_name}}"
    @echo "Installed: {{install_dir}}/{{app_name}}"
