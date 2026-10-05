# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Browse::Budget do
  it "restores the previous statement timeout after successful and canceled reads" do
    connection = Traces::Trace.connection
    original = connection.select_value("SHOW statement_timeout")
    described_class.within { expect(connection.select_value("SHOW statement_timeout")).to eq("1s") }
    expect(connection.select_value("SHOW statement_timeout")).to eq(original)
    # Leave scheduling margin between the database timeout and query completion.
    expect { described_class.within { connection.execute("SELECT pg_sleep(3)") } }.to raise_error(Traces::Browse::Unavailable)
    expect(connection.select_value("SHOW statement_timeout")).to eq(original)
    expect(connection.select_value("SELECT 1")).to eq(1)
  end

  it "loads model column metadata before applying the lookup timeout" do
    events = []
    [ Traces::Trace, Traces::Span ].each { |model| allow(model).to receive(:columns_hash).and_wrap_original { |method, *args| events << :metadata; method.call(*args) } }
    observer = ->(_name, _start, _finish, _id, data) { events << :timeout if data[:sql] == "SET LOCAL statement_timeout = '1s'" }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { described_class.within { nil } }
    expect(events.take(2)).to eq([ :metadata, :metadata ])
    expect(events).to include(:timeout)
  end
end
