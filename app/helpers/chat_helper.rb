# frozen_string_literal: true

# Helper della chat per l'area member. Il badge non-letti in sidebar riusa il ledger delle notifiche
# (Alerting::Notification) invece di ricalcolare per-conversazione: le notifiche di chat non lette
# in-app sono la stessa cosa che l'utente deve "smaltire", ed è una query indicizzata.
module ChatHelper
  def chat_unread_count
    return 0 if Current.account.nil?

    Alerting::Notification
      .where(account_id: Current.account.id, via: :in_app)
      .where(event_type: %i[chat_message chat_mentioned])
      .unread.count
  end

  # Il viewer vede ANCORA la risorsa taggata? (revoca live: perdere il progetto oscura anche i
  # riferimenti già postati). visible_project_ids nil = render at-post-time (broadcast): i riferimenti
  # sono appena stati validati "in comune" da Chat::References::Parse → visibili per costruzione.
  def chat_reference_visible?(referable, visible_project_ids)
    return true if visible_project_ids.nil?

    project_id = referable.is_a?(Projects::Project) ? referable.id : referable.try(:project_id)
    visible_project_ids.include?(project_id)
  end

  # Separator above the first message of each day in a thread: "Today", "Yesterday", then "28 Sep".
  def chat_day_label(date)
    today = Time.zone.today
    return t("member.chat.days.today") if date == today
    return t("member.chat.days.yesterday") if date == today - 1

    l(date, format: :day_month)
  end
end
