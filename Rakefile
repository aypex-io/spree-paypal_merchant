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
  ENV['LIB_NAME'] = 'spree/paypal_merchant'
  ENV['DB'] ||= 'postgres'
  # Spree 6's extension:test_app takes no install_storefront/install_admin options.
  Rake::Task['extension:test_app'].execute
end
