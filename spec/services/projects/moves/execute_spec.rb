# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Moves::Execute do
  let(:owner) { create(:account) }
  let(:source) { create(:organization) }
  let(:destination) { create(:organization) }
  let(:source_env) { create(:environment, organization: source, code: "production") }
  let(:project) { create(:project, organization: source) }
  let(:move) do
    create(:project_move, subject: project, destination_organization: destination, requested_by: owner)
  end

  before do
    create(:membership, account: owner, organization: source, role: :owner)
    create(:membership, account: owner, organization: destination, role: :owner)
    project.environments << source_env
  end

  let!(:variable) { create(:secret_variable, project:, environment: source_env, name: "API_KEY", value: "k-123") }
  let!(:ticket) { create(:ticket, project:, reporter: owner, reviewer: owner) }

  it "moves the project and keeps every secret readable" do
    expect(described_class.call(move:)).to be_ok

    expect(project.reload.organization_id).to eq(destination.id)
    variable.reload
    expect(variable.organization_id).to eq(destination.id)
    expect(variable.environment.organization_id).to eq(destination.id)
    expect(variable.environment.code).to eq("production")
    expect(variable.value).to eq("k-123")
    expect(Secrets::Variable.where(organization_id: source.id)).to be_empty
    expect(move.reload).to be_succeeded
  end

  it "is not blocked by its own active move" do
    expect(move).to be_pending

    expect(described_class.call(move:)).to be_ok
  end

  it "remaps ticket status and priority to the destination lookups" do
    described_class.call(move:)
    ticket.reload
    expect(ticket.status.organization_id).to eq(destination.id)
    expect(ticket.priority.organization_id).to eq(destination.id)
  end

  it "reuses a destination status with the same code and creates a missing one" do
    existing = create(:ticket_status, organization: destination, code: ticket.status.code)
    review = create(:ticket_status, :in_progress, organization: source, code: "qa_review")
    reviewed = create(:ticket, project:, reporter: owner, reviewer: owner, status: review)

    described_class.call(move:)

    expect(ticket.reload.status_id).to eq(existing.id)
    created = reviewed.reload.status
    expect([ created.organization_id, created.code, created.label ]).to eq([ destination.id, "qa_review", review.label ])
  end

  it "keeps the project token valid" do
    token = create(:project_token, project:, environment: source_env)
    described_class.call(move:)
    expect(Projects::Token.active.find_by(token_digest: token.token_digest).project.organization_id).to eq(destination.id)
    expect(token.reload.environment.organization_id).to eq(destination.id)
  end

  it "keeps the secrets bundle identical, shared secrets included" do
    shared = Secrets::Shared::Variable.create!(organization: source, name: "DATABASE_URL")
    Secrets::Shared::Delegation.create!(shared_value: shared.values.create!(environment: source_env, value: "postgres://one"),
                                        project:)
    before_move = Secrets::Bundle.call(project:, environment: source_env, account: owner).value

    described_class.call(move:)

    project.reload
    environment = project.environments.find_by!(code: "production")
    expect(environment.organization_id).to eq(destination.id)
    expect(Secrets::Bundle.call(project:, environment:, account: owner).value).to eq(before_move)
    expect(before_move).to eq("API_KEY" => "k-123", "DATABASE_URL" => "postgres://one")
  end

  it "changes nothing when it fails half way" do
    shared = Secrets::Shared::Variable.create!(organization: source, name: "DATABASE_URL")
    Secrets::Shared::Delegation.create!(shared_value: shared.values.create!(environment: source_env, value: "postgres://one"),
                                        project:)
    allow(Projects::Moves::Detach).to receive(:apply!).and_raise(ActiveRecord::StatementInvalid, "boom")

    result = described_class.call(move:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PROJECTMOVE-002")
    expect(project.reload.organization_id).to eq(source.id)
    expect(variable.reload.organization_id).to eq(source.id)
    expect(ticket.reload.status.organization_id).to eq(source.id)
    expect(Types::Environment.where(organization: destination, code: "production")).to be_empty
    expect(Types::TicketStatus.where(organization: destination)).to be_empty
    expect(Secrets::Shared::Variable.where(organization: destination)).to be_empty
    expect(move.reload).to be_failed
    expect(move.error_message).to include("boom")
  end

  it "refuses a move that is no longer pending and leaves its status alone" do
    move.update!(status: :succeeded)

    result = described_class.call(move:)

    expect(result.error.code).to eq("R409-PROJECTMOVE-006")
    expect(move.reload).to be_succeeded
    expect(project.reload.organization_id).to eq(source.id)
  end

  it "rolls back its own writes when called inside an outer transaction" do
    allow(Projects::Moves::Detach).to receive(:apply!).and_raise(ActiveRecord::StatementInvalid, "boom")

    ApplicationRecord.transaction { described_class.call(move:) }

    expect(project.reload.organization_id).to eq(source.id)
    expect(Types::Environment.where(organization: destination, code: "production")).to be_empty
    expect(move.reload).to be_failed
  end

  context "with a shared file lent to the project" do
    let(:bytes) { "-----BEGIN PRIVATE KEY-----x" }
    let!(:asset) do
      record = Secrets::Asset.new(organization: source, name: "AuthKey", environment: source_env)
      file = Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream", original_filename: "AuthKey.p8")
      Secrets::Assets::Upload.call(asset: record, uploaded_file: file, actor: nil)
      Secrets::AssetDelegation.create!(asset: record, project:)
      record
    end

    around do |example|
      previous = ENV["SECRET_ASSETS_MASTER_KEY"]
      ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
      example.run
    ensure
      ENV["SECRET_ASSETS_MASTER_KEY"] = previous
    end

    it "copies the file so it decrypts to the same bytes after the move" do
      expect(described_class.call(move:)).to be_ok

      copy = Secrets::AssetDelegation.find_by!(project:).asset
      expect(copy.organization_id).to eq(destination.id)
      expect(Secrets::Assets::Download.call(version: copy.current_version, actor: nil).value).to eq(bytes)
    end

    it "deletes the stored copy when the move rolls back after copying" do
      allow(Projects::Moves::Detach).to receive(:apply!).and_raise(ActiveRecord::StatementInvalid, "boom")
      keys = []
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original { |original, **options| original.call(**options).tap { keys << _1.key } }

      described_class.call(move:)

      expect(keys.size).to eq(1)
      expect(ActiveStorage::Blob.service.exist?(keys.first)).to be(false)
    end

    it "keeps the stored copy when marking the move succeeded fails after the commit" do
      keys = []
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original { |original, **options| original.call(**options).tap { keys << _1.key } }
      allow(move).to receive(:update!).and_call_original
      allow(move).to receive(:update!).with(hash_including(status: :succeeded)).and_raise(ActiveRecord::StatementInvalid, "boom")

      described_class.call(move:)

      expect(project.reload.organization_id).to eq(destination.id)
      expect(ActiveStorage::Blob.service.exist?(keys.sole)).to be(true)
    end

    it "changes nothing when the copied file cannot be stored" do
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, "storage down")

      result = described_class.call(move:)

      expect(result).to be_err
      expect(project.reload.organization_id).to eq(source.id)
      expect(Secrets::AssetDelegation.find_by!(project:).asset_id).to eq(asset.id)
      expect(Secrets::Asset.where(organization: destination)).to be_empty
      expect(move.reload).to be_failed
      expect(move.error_message).to include("storage down")
    end
  end

  it "stops without changes when a blocker appeared after the preview" do
    create(:project, organization: destination, key: project.key)

    result = described_class.call(move:)

    expect(result.error.code).to eq("R409-PROJECTMOVE-001")
    expect(project.reload.organization_id).to eq(source.id)
    expect(move.reload).to be_failed
  end

  describe "a blocker found under the locks" do
    def database_state
      [ project.reload.attributes, variable.reload.attributes, ticket.reload.attributes,
        Types::Environment.where(organization: destination).pluck(:id), Types::TicketStatus.where(organization: destination).count,
        Secrets::Shared::Variable.where(organization: destination).count, Activity::Event.count ]
    end

    blockers = {
      "key_taken" => -> { create(:project, organization: destination, key: project.key) },
      "person_not_member" => -> { project.update_columns(cto_id: create(:membership, organization: source).account_id) },
      "provision_crosses" => lambda do
        other = create(:project, organization: source)
        other.environments << source_env
        create(:secret_provision, organization: source, source_project: project, destination_project: other,
                                  source_environment: source_env, destination_environment: source_env)
      end,
      "shared_conflict" => lambda do
        shared = Secrets::Shared::Variable.create!(organization: source, name: "DATABASE_URL")
        Secrets::Shared::Delegation.create!(shared_value: shared.values.create!(environment: source_env, value: "one"), project:)
        Secrets::Shared::Variable.create!(organization: destination, name: "DATABASE_URL")
                                 .values.create!(environment: create(:environment, organization: destination, code: "production"),
                                                 value: "two")
      end,
      "agent_running" => -> { ticket.create_agent_workflow!(triage_requested_at: Time.current) },
      "move_in_progress" => lambda do
        group = create(:group, organization: source)
        project.update_columns(group_id: group.id)
        create(:project_move, subject: group, destination_organization: destination)
      end,
      "subject_left_source" => -> { project.update_columns(organization_id: create(:organization).id) },
      "requester_not_owner" => -> { Connections::Membership.find_by!(account: owner, organization: destination).update_columns(role: :admin) }
    }

    blockers.each do |code, setup|
      it "stops on #{code} and changes nothing" do
        move
        instance_exec(&setup)
        before = database_state

        result = described_class.call(move:)

        expect(result.error.code).to eq("R409-PROJECTMOVE-001")
        expect(move.reload).to be_failed
        expect(move.error_message).to include(code)
        expect(database_state).to eq(before)
      end
    end
  end

  it "remaps the platforms and statuses of a moved group's features" do
    group = create(:group, organization: source)
    platform = create(:feature_platform, feature: create(:product_feature, category: create(:product_category, group:)))
    codes = [ platform.platform.code, platform.status.code ]
    group_move = create(:project_move, subject: group, destination_organization: destination, requested_by: owner)

    expect(described_class.call(move: group_move)).to be_ok

    platform.reload
    expect([ platform.platform.organization_id, platform.status.organization_id ]).to all(eq(destination.id))
    expect([ platform.platform.code, platform.status.code ]).to eq(codes)
  end

  it "stops a project move once its group has already taken the project elsewhere" do
    group = create(:group, organization: source)
    project.update!(group:)
    group_move = create(:project_move, subject: group, destination_organization: destination, requested_by: owner)
    expect(described_class.call(move: group_move)).to be_ok
    third = create(:organization)
    create(:membership, account: owner, organization: third, role: :owner)
    late = create(:project_move, subject: project.reload, source_organization: source, destination_organization: third,
                                 requested_by: owner)

    result = described_class.call(move: late)

    expect(result.error.code).to eq("R409-PROJECTMOVE-001")
    expect(late.reload.error_message).to include("subject_left_source")
    expect(project.reload.organization_id).to eq(destination.id)
  end

  it "records the move in the history of both organizations" do
    described_class.call(move:)
    actions = Activity::Event.where(subject: project).pluck(:organization_id, :action)
    expect(actions).to include([ source.id, "moved_out" ], [ destination.id, "moved_in" ])
  end

  it "keeps the history of an earlier source organization when the project moves again" do
    third = create(:organization)
    create(:membership, account: owner, organization: third, role: :owner)
    described_class.call(move:)
    second_move = create(:project_move, subject: project.reload, destination_organization: third, requested_by: owner)

    expect(described_class.call(move: second_move)).to be_ok

    actions = Activity::Event.where(subject: project).pluck(:organization_id, :action)
    expect(actions).to include([ source.id, "moved_out" ], [ destination.id, "moved_out" ], [ third.id, "moved_in" ])
  end

  it "deletes a team access the source organization keeps" do
    access = create(:team_project_access, team: create(:team, organization: source), project:)

    described_class.call(move:)

    expect(Connections::TeamProjectAccess.exists?(access.id)).to be(false)
  end

  it "drops a watcher who is not a member of the destination" do
    watcher = create(:account)
    create(:membership, account: watcher, organization: source)
    create(:ticket_subscription, ticket:, account: watcher)

    described_class.call(move:)

    subscriptions = Ticketing::Subscription.where(ticket:)
    expect(subscriptions.pluck(:account_id)).not_to include(watcher.id)
    expect(subscriptions.pluck(:organization_id).uniq - [ destination.id ]).to be_empty
  end

  it "moves the project chat with its messages" do
    conversation = create(:chat_conversation, organization: source, contextable: project)
    message = create(:chat_message, conversation:, author: owner)

    described_class.call(move:)

    expect(conversation.reload.organization_id).to eq(destination.id)
    expect(message.reload.organization_id).to eq(destination.id)
  end

  describe "the chat of a moved project" do
    let(:conversation) { create(:chat_conversation, organization: source, contextable: project) }

    it "moves its participants so the destination chat keeps working, dropping non-members" do
      outsider = create(:account)
      create(:chat_participant, conversation:, account: owner)
      create(:chat_participant, conversation:, account: outsider)

      expect(described_class.call(move:)).to be_ok

      participant = Chat::Participant.ensure_for(conversation: conversation.reload, account: owner)
      expect(participant.organization_id).to eq(destination.id)
      expect { participant.mark_read! }.not_to raise_error
      expect(Chat::Participant.where(conversation:).pluck(:account_id)).to eq([ owner.id ])
    end

    it "moves references to moved data and deletes references to what the source keeps" do
      message = create(:chat_message, conversation:, author: owner)
      moved = [ project, create(:error_group, project:) ].map { create(:chat_message_reference, message:, referable: _1) }
      behind = create(:chat_message_reference, message:, referable: create(:project, organization: source))

      expect(described_class.call(move:)).to be_ok

      expect(moved.map { _1.reload.organization_id }).to all(eq(destination.id))
      expect(Chat::MessageReference.exists?(behind.id)).to be(false)
    end
  end

  it "detaches every reference to moved data from messages the source keeps" do
    message = create(:chat_message, conversation: create(:chat_conversation, organization: source), author: owner)
    targets = [ project, ticket, create(:error_group, project:), create(:metric_group, project:) ]
    references = targets.map { create(:chat_message_reference, message:, referable: _1) }
    kept = create(:chat_message_reference, message:, referable: create(:project, organization: source))

    expect(described_class.call(move:)).to be_ok

    expect(Chat::MessageReference.where(id: references.map(&:id))).to be_empty
    expect(kept.reload.organization_id).to eq(source.id)
  end

  it "moves the history of the project's documents, milestones, datasets and ideas" do
    records = [ create(:document, project:), create(:milestone, project:), create(:dataset, project:),
                create(:idea, project:, organization: source) ]
    events = records.map { create(:activity_event, subject: _1, organization: source) }

    expect(described_class.call(move:)).to be_ok

    expect(events.map { _1.reload.organization_id }).to all(eq(destination.id))
  end

  it "detaches the project from a group the source organization keeps" do
    project.update!(group: create(:group, organization: source))

    described_class.call(move:)

    expect(project.reload.group_id).to be_nil
  end

  it "detaches a GitHub repository whose rows are referenced by agent deliveries" do
    repository = create(:github_repository, project:)
    other = create(:project, organization: source)
    workflow = create(:agent_workflow, ticket: create(:ticket, project: other, reporter: owner, reviewer: owner))
    candidate = create(:agent_delivery_candidate, workflow:, attempt: create(:agent_attempt, workflow:, phase: "autopilot"),
                                                  repository:)
    Agents::ReleaseAssignment.create!(workflow:, github_repository: repository, execution_phase: "closer_staging",
                                      version: "1.0.0")

    expect(described_class.call(move:)).to be_ok

    expect(Github::Repository.exists?(repository.id)).to be(false)
    expect(candidate.reload.repository_id).to be_nil
    expect(Agents::ReleaseAssignment.where(github_repository_id: repository.id)).to be_empty
  end

  context "with a group" do
    let(:group) { create(:group, organization: source) }
    let(:second) { create(:project, organization: source, group:) }
    let(:move) do
      create(:project_move, subject: group, destination_organization: destination, requested_by: owner)
    end

    before { project.update!(group:) }

    it "moves the group, all its projects and its product categories" do
      category = create(:product_category, group:)
      second_ticket = create(:ticket, project: second, reporter: owner, reviewer: owner)

      expect(described_class.call(move:)).to be_ok

      expect(group.reload.organization_id).to eq(destination.id)
      expect([ project.reload, second.reload ].map(&:organization_id)).to all(eq(destination.id))
      expect([ project.group_id, second.group_id ]).to all(eq(group.id))
      expect(category.reload.organization_id).to eq(destination.id)
      expect(second_ticket.reload.status.organization_id).to eq(destination.id)
      expect(Activity::Event.where(subject: group).pluck(:organization_id, :action))
        .to include([ source.id, "moved_out" ], [ destination.id, "moved_in" ])
    end
  end
end
