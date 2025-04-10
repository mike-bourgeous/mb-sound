# File to be included via simplecov_runner.rb when testing standalone scripts from bin/
require 'securerandom'
require 'simplecov'

SimpleCov.start do
  command_name "#{$0} #{$$} #{SecureRandom.uuid}"
  formatter SimpleCov::Formatter::SimpleFormatter
  minimum_coverage 0
  enable_coverage :branch
end

# This require line makes sure the original script file is processed by simplecov
require File.expand_path($0, '.')

exit 0
