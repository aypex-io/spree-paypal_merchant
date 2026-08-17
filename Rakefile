# frozen_string_literal: true

require 'bundler'
Bundler::GemHelper.install_tasks

require 'rspec/core/rake_task'
require 'spree/testing_support/extension_rake'

RSpec::Core::RakeTask.new

task :default do
  if Dir['spec/dummy'].empty?
    Rake::Task[:test_app].invoke
    Dir.chdir('../../')
  end
  Rake::Task[:spec].invoke
end

desc 'Generates a dummy app for testing'
task :test_app do
  # Must be the require path, not the gem name: spree_core's common:test_app
  # does a literal `require ENV['LIB_NAME']` and constantizes
  # "#{LIB_NAME.camelize}::Generators::InstallGenerator".
  ENV['LIB_NAME'] = 'spree/paypal_checkout'
  ENV['DB'] ||= 'postgres'
  Rake::Task['extension:test_app'].execute(install_storefront: true, install_admin: true)
end
