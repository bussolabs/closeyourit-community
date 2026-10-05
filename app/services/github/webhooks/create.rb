# frozen_string_literal: true

module Github
  module Webhooks
    # Evento `create`: emesso alla creazione di un tag o branch. Tag (ref_type "tag") → binding
    # tag→release. Branch (ref_type "branch") → aggancio al ticket via prefisso KEY-N nel nome.
    class Create < Base
      def call
        case value_at(@payload, "ref_type")
        when "tag"    then bind_tag(value_at(@payload, "ref").to_s)
        when "branch" then attach_branch(value_at(@payload, "ref").to_s)
        else Result.ok(nil)
        end
      end

      private

      def attach_branch(name)
        repo = repository
        return Result.ok(nil) if repo.nil? || !repo.sync_enabled? || name.blank?

        ticket = ticket_from(name)
        record = repo.branches.find_or_initialize_by(name: name)
        created = record.new_record?
        record.ticket = ticket if ticket
        record.html_url = "https://github.com/#{repo.full_name}/tree/#{name}" if record.html_url.blank?
        record.save!

        record_activity(ticket, "branch_created", branch: name) if created && ticket
        Result.ok(record)
      end
    end
  end
end
