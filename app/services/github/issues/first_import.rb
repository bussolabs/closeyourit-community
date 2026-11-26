# frozen_string_literal: true

module Github
  module Issues
    # The first import when a project turns the sync on: only the issues still open (or the cards on the
    # board), one page per run, without notifying the team — a repository with thousands of issues would
    # otherwise send thousands of messages in one go. The last page starts the nightly check's clock. CYRA-1055
    class FirstImport < ApplicationService
      def initialize(repository:, page: 1, client: Github::Client.new)
        @repository = repository
        @page = page
        @client = client
      end

      # Ok(next page) while there is more to read, Ok(nil) when done.
      def call
        return Result.ok(nil) unless @repository.issue_sync_live?

        started_at = Time.current
        more = @repository.issue_sync_board_issues? ? board_page : issues_page
        @repository.update_columns(issues_reconciled_at: started_at) unless more
        Result.ok(more ? @page + 1 : nil)
      end

      private

      def issues_page
        batch = @client.repository_issues(@repository.github_installation_id, @repository.full_name, state: "open", page: @page)
        batch.each { |issue| Import.call(repository: @repository, issue:, notify: false, with_comments: true) }
        batch.size >= Github::Client::ISSUES_PAGE_SIZE
      end

      # The board is read whole; its issues are imported a page at a time. No board chosen yet: nothing to read.
      def board_page
        return false unless @repository.board_configured?

        items =@client.board_items(@repository.github_installation_id, @repository.board_node_id)
                       .select { |item| item[:repo_id] == @repository.repo_id }
        page = items.each_slice(Github::Client::ISSUES_PAGE_SIZE).to_a[@page - 1].to_a
        page.each { |item| board_item(item) }
        items.size > @page * Github::Client::ISSUES_PAGE_SIZE
      end

      def board_item(item)
        return if @repository.issues.exists?(number: item[:number])

        issue = @client.issue(@repository.github_installation_id, @repository.full_name, item[:number])
        return if issue.nil? || issue["state"] == "closed"

        Import.call(repository: @repository, issue:, board_item: item, notify: false, with_comments: true)
      end
    end
  end
end
