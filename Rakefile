require "bundler/gem_tasks"
require 'rake/extensiontask'

task :default => :spec

Rake::ExtensionTask.new 'mb-fast_sound' do |ext|
  ext.name = 'fast_sound'
  ext.ext_dir = 'ext/mb/fast_sound'
  ext.lib_dir = 'lib/mb'
end

Rake::ExtensionTask.new 'mb-sound-fast_resample' do |ext|
  ext.name = 'fast_resample'
  ext.ext_dir = 'ext/mb/sound/fast_resample'
  ext.lib_dir = 'lib/mb/sound'
end
