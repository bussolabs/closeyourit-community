# frozen_string_literal: true

module Member
  # CYRA-1162 — «Later» raises the threshold, «No, thanks» turns the request off for good. Saved on the
  # person's own row, so the choice holds on every device.
  class ReferralPromptsController < Member::BaseController
    permission_not_required "Referral prompt: a personal choice, written on one's own account."

    CHOICES = %w[later never].freeze

    def update
      choice = params[:choice].to_s
      return head :unprocessable_content unless CHOICES.include?(choice)
      # The person's own choice: whoever stands in for them does not make it.
      return head :forbidden if Current.true_account != Current.account

      if choice == "never"
        ::Accounts::ReferralPrompt.decline!(Current.account)
      else
        ::Accounts::ReferralPrompt.postpone!(Current.account)
      end
      redirect_back_or_to member_tickets_path, status: :see_other
    end
  end
end
