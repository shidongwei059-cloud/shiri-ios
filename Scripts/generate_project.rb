#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
project_path = File.join(root, 'Shiri.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.object_version = '56' if project.respond_to?(:object_version=)
configuration = project.main_group.new_group('Configuration', 'Configuration')
base = configuration.new_file('Base.xcconfig')
configuration.new_file('Local.example.xcconfig')
project.build_configurations.each { |c| c.base_configuration_reference = base; c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'; c.build_settings['SWIFT_VERSION'] = '5.0' }
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
project.root_object.package_references << package
def add_core(project, target, package)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = 'ShiriCore'
  target.package_product_dependencies << dependency
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = dependency
  target.frameworks_build_phase.files << build
end
def add_files(project, target, root, directory)
  group = project.main_group.new_group(directory, directory)
  Dir.glob(File.join(root, directory, '**', '*.swift')).sort.each do |path|
    reference = group.new_file(path.delete_prefix(File.join(root, directory) + '/'))
    target.source_build_phase.add_file_reference(reference)
  end
  group
end
app = project.new_target(:application, 'Shiri', :ios, '16.0')
add_core(project, app, package)
group = add_files(project, app, root, 'Shiri')
%w[Resources/Assets.xcassets Resources/LaunchScreen.storyboard Resources/PrivacyInfo.xcprivacy Resources/Fonts/NotoSerifSC.ttf Resources/Fonts/OFL.txt].each { |path| app.resources_build_phase.add_file_reference(group.new_file(path)) }
group.new_file('Info.plist')
group.new_file('Shiri.entitlements')
app.build_configurations.each do |c|
  c.base_configuration_reference = base
  c.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => '$(SHIRI_BUNDLE_ID)', 'INFOPLIST_FILE' => 'Shiri/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO', 'PRODUCT_NAME' => 'Shiri', 'CODE_SIGN_ENTITLEMENTS' => 'Shiri/Shiri.entitlements',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
    'SWIFT_EMIT_LOC_STRINGS' => 'YES', 'SWIFT_STRICT_CONCURRENCY' => 'targeted',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'ENABLE_PREVIEWS' => 'YES', 'SUPPORTS_MACCATALYST' => 'NO', 'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD' => 'NO'
  })
  c.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = 'Shiri/ShiriSimulator.entitlements' if c.name == 'Debug'
end
shared_group = add_files(project, app, root, 'ShiriSystem')
widgets = project.new_target(:app_extension, 'ShiriWidgets', :ios, '16.0')
share = project.new_target(:app_extension, 'ShiriShareExtension', :ios, '16.0')
[widgets, share].each do |target|
  add_core(project, target, package)
  extension_group = add_files(project, target, root, target.name)
  extension_group.new_file('Info.plist')
  extension_group.new_file(target.name + '.entitlements')
  target.build_configurations.each do |c|
    c.base_configuration_reference = base
    suffix = target == widgets ? 'widgets' : 'share'
    c.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'$(SHIRI_BUNDLE_ID).' + suffix, 'INFOPLIST_FILE'=>target.name + '/Info.plist', 'GENERATE_INFOPLIST_FILE'=>'NO', 'CODE_SIGN_ENTITLEMENTS'=>target.name + '/' + target.name + '.entitlements', 'APPLICATION_EXTENSION_API_ONLY'=>'YES', 'SKIP_INSTALL'=>'YES', 'LD_RUNPATH_SEARCH_PATHS'=>['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']})
  end
  app.add_dependency(target)
end
shared_group.files.each { |file| widgets.source_build_phase.add_file_reference(file) }
share.source_build_phase.add_file_reference(group.files.find { |file| file.path == 'Infrastructure/PhotoProcessor.swift' })
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
[widgets, share].each { |target| build_file = embed.add_file_reference(target.product_reference); build_file.settings = {'ATTRIBUTES'=>['RemoveHeadersOnCopy']} }
tests = project.new_target(:ui_test_bundle, 'ShiriUITests', :ios, '16.0')
tests.add_dependency(app)
add_files(project, tests, root, 'ShiriUITests')
tests.build_configurations.each do |c|
  c.base_configuration_reference = base
  c.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'$(SHIRI_BUNDLE_ID).uitests', 'GENERATE_INFOPLIST_FILE'=>'YES', 'TEST_TARGET_NAME'=>'Shiri', 'SWIFT_VERSION'=>'5.0'})
end
unit_tests = project.new_target(:unit_test_bundle, 'ShiriAppTests', :ios, '16.0')
unit_tests.add_dependency(app)
add_core(project, unit_tests, package)
unit_group = add_files(project, unit_tests, root, 'ShiriAppTests')
unit_tests.build_configurations.each do |c|
  c.base_configuration_reference = base
  c.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'$(SHIRI_BUNDLE_ID).apptests', 'GENERATE_INFOPLIST_FILE'=>'YES', 'TEST_HOST'=>'$(BUILT_PRODUCTS_DIR)/Shiri.app/Shiri', 'BUNDLE_LOADER'=>'$(TEST_HOST)', 'SWIFT_VERSION'=>'5.0'})
end
project.root_object.attributes['LastUpgradeCheck'] = '2660'
project.root_object.attributes['TargetAttributes'] = {app.uuid=>{'CreatedOnToolsVersion'=>'26.6'}, tests.uuid=>{'CreatedOnToolsVersion'=>'26.6', 'TestTargetID'=>app.uuid}}
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project_path, 'Shiri', true)
test_scheme = Xcodeproj::XCScheme.new
test_scheme.add_build_target(app)
test_scheme.add_test_target(unit_tests)
test_scheme.set_launch_target(app)
test_scheme.save_as(project_path, 'ShiriAppTests', true)
puts "Generated #{project_path}"
