# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::DeleteComment do
  let(:org) { create(:organization) }
  let(:ticket) { create(:ticket, organization: org) }
  let(:author) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
  end
  let(:comment) { create(:ticket_comment, ticket: ticket, author: author) }

  it "elimina il commento (Result.ok)" do
    comment
    expect do
      described_class.call(comment: comment, actor: author)
    end.to change(Ticketing::Comment, :count).by(-1)
  end

  it "preserva i commenti automatici come audit immutabile" do
    comment.update!(body: "Domanda\n<!-- closeyourit-automation:clarification -->")

    result = nil
    expect do
      result = described_class.call(comment:, actor: author)
    end.not_to change(Ticketing::Comment, :count)

    expect(result.error.code).to eq("R409-COMMENT-001")
  end

  it "blocca ticket prima del commento secondo il protocollo del claim queue" do
    comment
    expect(ticket).to receive(:lock!).ordered.and_call_original
    expect(comment).to receive(:lock!).ordered.and_call_original

    described_class.call(comment:, actor: author)
  end

  it "registra un evento `comment_deleted` con attore e nome autore snapshottato (audit)" do
    comment
    expect do
      described_class.call(comment: comment, actor: author)
    end.to change(Ticketing::Event, :count).by(1)

    event = Ticketing::Event.last
    expect(event.action).to eq("comment_deleted")
    expect(event.actor).to eq(author)
    # author_name preservato: l'evento registra DI CHI era il commento eliminato (fidelity audit).
    expect(event.data).to eq("author_name" => author.name)
  end

  it "registra true_actor in impersonation" do
    god = create(:account)
    described_class.call(comment: comment, actor: author, true_actor: god)
    expect(Ticketing::Event.last.true_actor).to eq(god)
  end

  it "autore già rimosso (author nil) → author_name nil nell'evento, eliminazione comunque riuscita" do
    allow(comment).to receive(:author).and_return(nil)
    expect do
      described_class.call(comment: comment, actor: author)
    end.to change(Ticketing::Comment, :count).by(-1)
    expect(Ticketing::Event.last.data).to eq("author_name" => nil)
  end

  it "rollback atomico: se l'evento fallisce, il commento NON viene eliminato" do
    comment
    allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
    expect do
      described_class.call(comment: comment, actor: author)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(Ticketing::Comment.exists?(comment.id)).to be(true)
  end

  # Realtime dopo il commit: rimuove la bolla-commento dalla timeline (per dom_id) e aggiorna il
  # contatore. L'evento `comment_deleted` entra in timeline via RecordActivity (after-commit, suo spec).
  describe "broadcast realtime alla rimozione" do
    it "rimuove la bolla-commento e fa il replace del contatore sullo stream del ticket" do
      comment
      stream = Realtime::Streams.ticket(ticket)
      expect(Turbo::StreamsChannel).to receive(:broadcast_remove_to).with(
        stream, target: ActionView::RecordIdentifier.dom_id(comment)
      )
      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        stream, target: "ticket_comments_count_#{ticket.id}",
        partial: "member/tickets/comments_count", locals: anything
      )
      described_class.call(comment: comment, actor: author)
    end
  end
end
