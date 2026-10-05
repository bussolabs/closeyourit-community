# frozen_string_literal: true

# The move pages serve a project and a group alike: these pick the right route (CYRA-879).
module ProjectMovesHelper
  # The move button shows only to the owner of this organization who owns at least one other (CYRA-879).
  def project_move_available?
    return false unless current_membership&.owner?

    Connections::Membership.where(account: Current.account, role: :owner)
                           .where.not(organization_id: Current.organization.id).exists?
  end

  def new_project_move_path_for(subject)
    subject.group? ? new_member_group_move_path(subject.record) : new_member_project_move_path(subject.record)
  end

  def preview_project_move_path_for(subject, **query)
    record = subject.record
    subject.group? ? preview_member_group_move_path(record, **query) : preview_member_project_move_path(record, **query)
  end

  def create_project_move_path_for(subject)
    subject.group? ? member_group_move_path(subject.record) : member_project_move_path(subject.record)
  end

  # Where the subject lives in the source organization: the page the move was started from (CYRA-879).
  def project_move_origin_path(subject)
    subject.group? ? member_group_path(subject.record) : member_project_settings_path(subject.record)
  end

  # The subject's own page, reached through the organization switch once it lives in the destination (CYRA-879).
  def project_move_destination_path(subject)
    subject.group? ? member_group_path(subject.record) : member_project_path(subject.record)
  end

  # `link: false` once the subject has left this organization: its pages would answer 404 (CYRA-879).
  def project_move_breadcrumb(subject, current, link: true)
    trail = [ { label: t("member.projects.title"), href: member_projects_path } ]
    trail << { label: t("member.groups.title"), href: member_groups_path } if subject.group?
    trail << { label: subject.record.name, href: (project_move_origin_path(subject) if link) }
    trail << { label: current }
  end

  # A lookup copied by code, an organization secret or file copied with its environment (CYRA-879),
  # or the Knowledge pages and books that move along (CYRA-882).
  def project_move_creation_text(creation)
    scope = "member.project_moves.creations"
    case creation[:table]
    when "knowledge_pages" then t("#{scope}.knowledge_pages", count: creation[:count])
    when "knowledge_books" then project_move_book_text(creation)
    when "secrets_shared" then project_move_shared_text(creation)
    else t("#{scope}.#{creation[:table]}", label: creation[:label], code: creation[:code])
    end
  end

  # Several source books with one title end in a single destination book: the text says so (CYRA-882).
  def project_move_book_text(creation)
    books = creation[:books].to_i
    key = books > 1 ? "#{creation[:outcome]}_merged" : creation[:outcome]
    t("member.project_moves.creations.knowledge_books.#{key}", title: creation[:title], books:)
  end

  def project_move_shared_text(creation)
    environment = creation[:environment_code]
    key = environment ? creation[:kind] : "#{creation[:kind]}_any_environment"
    t("member.project_moves.creations.secrets_shared.#{key}", name: creation[:name], environment:)
  end

  def project_move_detachment_text(detachment)
    t("member.project_moves.detachments.#{detachment[:table]}", count: detachment[:count])
  end

  def project_move_status_color(move)
    { "pending" => :gray, "running" => :indigo, "succeeded" => :emerald, "failed" => :red }.fetch(move.status)
  end
end
