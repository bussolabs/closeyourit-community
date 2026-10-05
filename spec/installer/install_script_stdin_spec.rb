# frozen_string_literal: true

require "rails_helper"

# Through `curl | bash` the script IS stdin: a command that reads stdin (docker compose exec -T)
# swallowed the rest and the install stopped before printing the password (CYRA-914 B4).
RSpec.describe "installer/install.sh under a pipe" do
  let(:script) { Rails.root.join("installer/install.sh").read }

  it "runs everything from main, called on the last line, so bash reads the whole script first" do
    expect(script).to match(/^main\(\) \{$/)
    expect(script.rstrip.lines.last).to eq('main "$@"')
  end
end
