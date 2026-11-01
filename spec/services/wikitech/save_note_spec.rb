# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::SaveNote do
  let(:organization) { create(:organization) }
  let(:author) { create(:account) }
  let(:params) do
    { body: "Godot is an open-source engine for 2D and 3D games.",
      source_label: "TikTok @github.signals", source_url: "https://www.tiktok.com/@github.signals/video/1",
      source_published_at: "2026-10-18T10:00:00Z", links: [ "https://github.com/godotengine/godot" ] }
  end

  def save(overrides = {}) = described_class.call(organization: organization, author: author, params: params.merge(overrides))

  it "stores a new pending note with its source and links and queues its processing" do
    result = nil
    expect { result = save }.to have_enqueued_job(Wikitech::ProcessNoteJob)

    expect(result).to be_ok
    note = result.value.note
    expect(result.value.duplicate).to be(false)
    expect(note).to be_status_pending
    expect(note.organization).to eq(organization)
    expect(note.created_by).to eq(author)
    expect(note.links).to eq([ "https://github.com/godotengine/godot" ])
    expect(note.source_published_at).to eq(Time.zone.parse("2026-10-18T10:00:00Z"))
  end

  it "returns the stored note instead of a duplicate when the same text comes again" do
    first = save.value.note

    second = save(body: "  #{params[:body]}\r\n")

    expect(second.value.duplicate).to be(true)
    expect(second.value.note).to eq(first)
    expect(organization.wikitech_notes.count).to eq(1)
  end

  it "keeps notes of different organizations apart" do
    save
    other = described_class.call(organization: create(:organization), author: author, params: params)

    expect(other.value.duplicate).to be(false)
  end

  it "refuses a blank body" do
    result = save(body: "   ")

    expect(result.error.code).to eq("R422-WIKITECH-001")
  end

  it "refuses a body over the limit" do
    result = save(body: "a" * (Wikitech::Constants::NOTE_BODY_MAX_CHARS + 1))

    expect(result.error.code).to eq("R422-WIKITECH-002")
  end

  it "refuses an address that is not http(s)" do
    result = save(links: [ "javascript:alert(1)" ])

    expect(result.error.code).to eq("R422-WIKITECH-003")
    expect(result.error.message).to include("javascript:alert(1)")
  end

  it "drops blank and repeated links and keeps at most the allowed number" do
    many = Array.new(Wikitech::Constants::NOTE_LINKS_MAX + 5) { |i| "https://example.com/#{i}" }

    note = save(links: [ "", "https://example.com/0", *many ]).value.note

    expect(note.links.size).to eq(Wikitech::Constants::NOTE_LINKS_MAX)
    expect(note.links.first).to eq("https://example.com/0")
  end

  it "returns the winner when an identical note is stored at the same moment" do
    winner = create(:wikitech_note, organization: organization, body: params[:body], source_url: params[:source_url])
    allow(organization.wikitech_notes).to receive(:find_by).and_return(nil, winner)
    allow(organization.wikitech_notes).to receive(:find_by!).and_return(winner)
    allow_any_instance_of(Wikitech::Note).to receive(:save).and_raise(ActiveRecord::RecordNotUnique) # rubocop:disable RSpec/AnyInstance

    result = save

    expect(result.value).to have_attributes(note: winner, duplicate: true)
  end
end
