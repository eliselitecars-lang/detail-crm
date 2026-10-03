# frozen_string_literal: true

# Adds the DetailCRMScreenshots UI-test target and a shared
# "DetailCRMScreenshots" scheme to ios/DetailCRM/DetailCRM.xcodeproj.
#
# CI ONLY (.github/workflows/screenshots.yml): the shipping project has no
# test target, and this change is never committed. The test sources live in
# ios/screenshots/DetailCRMScreenshots/, outside the app's synchronized
# folder (ios/DetailCRM/DetailCRM), so they are never compiled into the app.
#
#   cd ios && bundle exec ruby screenshots/add_ui_test_target.rb
#
# Idempotent: a project that already has the target is left as it is.

require "xcodeproj"

IOS_DIR = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(IOS_DIR, "DetailCRM", "DetailCRM.xcodeproj")
APP_TARGET = "DetailCRM"
TEST_TARGET = "DetailCRMScreenshots"
SOURCES_DIR = File.join(__dir__, TEST_TARGET)
DEPLOYMENT_TARGET = "17.0"

project = Xcodeproj::Project.open(PROJECT_PATH)
if project.targets.any? { |t| t.name == TEST_TARGET }
  puts "#{TEST_TARGET} is already in the project"
  exit 0
end

app = project.targets.find { |t| t.name == APP_TARGET }
abort "error: target #{APP_TARGET} not found in #{PROJECT_PATH}" unless app

sources = Dir[File.join(SOURCES_DIR, "*.swift")].sort
abort "error: no Swift files in #{SOURCES_DIR}" if sources.empty?

target = project.new_target(:ui_test_bundle, TEST_TARGET, :ios, DEPLOYMENT_TARGET, nil, :swift)
target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.detailcrm.app.screenshots"
  settings["TEST_TARGET_NAME"] = APP_TARGET
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["SWIFT_VERSION"] = "5.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["DEVELOPMENT_TEAM"] = ""
  settings["SWIFT_EMIT_LOC_STRINGS"] = "NO"
end
target.add_dependency(app)

# new_target links Foundation.framework by a path inside one specific SDK
# (e.g. iPhoneOS26.0.sdk); Swift links Foundation and XCTest by itself, so
# drop that reference rather than depend on the runner's SDK version.
target.frameworks_build_phase.files.to_a.each do |build_file|
  ref = build_file.file_ref
  build_file.remove_from_project
  ref&.remove_from_project
end
project.main_group.groups.select { |g| g.display_name == "Frameworks" }.each do |frameworks|
  frameworks.groups.select { |g| g.children.empty? }.each(&:remove_from_project)
  frameworks.remove_from_project if frameworks.children.empty?
end

# A plain group (not synchronized) pointing at ios/screenshots/DetailCRMScreenshots.
project_dir = File.dirname(PROJECT_PATH)
relative = Pathname.new(SOURCES_DIR).relative_path_from(Pathname.new(project_dir)).to_s
group = project.main_group.new_group(TEST_TARGET, relative)
refs = sources.map { |path| group.new_reference(File.basename(path)) }
target.add_file_references(refs)
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(target, false)
scheme.add_test_target(target)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, TEST_TARGET, true)

puts "Added #{TEST_TARGET} (#{sources.map { |s| File.basename(s) }.join(', ')}) and the #{TEST_TARGET} scheme " \
     "to #{PROJECT_PATH} (CI only; not committed)"
