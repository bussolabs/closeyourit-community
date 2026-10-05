# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

require_relative "config/application"

Rails.application.load_tasks

# Task della suite parallela locale (`parallel:create`, `parallel:prepare`): servono a preparare un
# database per processo, senza i quali gli otto processi si contendono lo stesso e falliscono a
# caso. La gem sta nel gruppo test, quindi il require vale solo dove quel gruppo esiste.
require "parallel_tests/tasks" if Rails.env.local?
