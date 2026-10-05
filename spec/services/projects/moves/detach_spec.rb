# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::Detach do
  let(:source) { create(:organization) }
  let(:project) { create(:project, organization: source) }
  let(:subject_) { Projects::Moves::Subject.new(project) }

  it "has a predicate that runs for every detached and lookup table of the registry" do
    tables = Projects::Moves::Registry::DETACH.keys | Projects::Moves::Registry::LOOKUPS.keys

    tables.each do |table|
      expect(described_class.predicate(table)).to be_present, "no predicate for #{table}"
      expect { described_class.scope(table, subject_).count }.not_to raise_error
    end
  end

  it "deletes the host exclusions of the deleted alerting rules first" do
    rule = create(:alerting_rule, :scoped, organization: source, project:)
    exclusion = Alerting::RuleHostExclusion.create!(rule:, host: create(:server_host, organization: source))
    kept = create(:alerting_rule, :scoped, organization: source)

    described_class.apply!(subject_)

    expect(Alerting::Rule.exists?(rule.id)).to be(false)
    expect(Alerting::RuleHostExclusion.exists?(exclusion.id)).to be(false)
    expect(Alerting::Rule.exists?(kept.id)).to be(true)
  end

  it "sets the nullified links to NULL and leaves other rows alone" do
    host = create(:agent_host, organization: source)
    host.update_columns(heartbeat_project_id: project.id)
    other = create(:agent_host, organization: source)
    other.update_columns(heartbeat_project_id: create(:project, organization: source).id)

    described_class.apply!(subject_)

    expect(host.reload.heartbeat_project_id).to be_nil
    expect(other.reload.heartbeat_project_id).not_to be_nil
  end

  it "counts only rows that still hold a nullified link" do
    create(:knowledge_sample_question, project:, knowledge_page_id: nil)

    expect(described_class.scope("knowledge_sample_questions", subject_).count).to eq(1)
    expect(described_class.affected("knowledge_sample_questions", subject_).count).to eq(0)
  end

  it "deletes a reference from the moved chat to a ticket the source keeps when the project has no tickets" do
    conversation = create(:chat_conversation, organization: source, contextable: project)
    message = create(:chat_message, conversation:)
    kept_ticket = create(:ticket, project: create(:project, organization: source))
    reference = create(:chat_message_reference, message:, referable: kept_ticket)

    described_class.apply!(subject_)

    expect(Chat::MessageReference.exists?(reference.id)).to be(false)
  end
end
