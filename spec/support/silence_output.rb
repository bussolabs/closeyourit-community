# frozen_string_literal: true

# Rake tasks talk to the operator through puts/warn/abort. In the suite that text lands in the CI
# log between the progress dots and reads like a real failure. Tag the example group with
# `:silence_output` to swallow it; the `output(...).to_stdout/.to_stderr` matchers still work,
# because they swap the streams again inside their own block.
RSpec.configure do |config|
  config.around(:each, :silence_output) do |example|
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    example.run
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end
end
