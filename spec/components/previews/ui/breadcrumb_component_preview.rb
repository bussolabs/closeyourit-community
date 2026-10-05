# frozen_string_literal: true

module Ui
  class BreadcrumbComponentPreview < ViewComponent::Preview
    # Index: Dashboard / <Risorsa> (corrente).
    def index
      render(Ui::BreadcrumbComponent.new(crumbs: [ { label: "Tickets" } ]))
    end

    # Show: Dashboard / Tickets / <item> (corrente).
    def show
      render(Ui::BreadcrumbComponent.new(crumbs: [
        { label: "Tickets", href: "#" },
        { label: "TS-142 · Login rotto" }
      ]))
    end

    # Nuovo: Dashboard / Tickets / Nuovo ticket (corrente).
    def new_form
      render(Ui::BreadcrumbComponent.new(crumbs: [
        { label: "Tickets", href: "#" },
        { label: "Nuovo ticket" }
      ]))
    end

    # Modifica: Dashboard / Tickets / <item> / Modifica (corrente).
    def edit_form
      render(Ui::BreadcrumbComponent.new(crumbs: [
        { label: "Tickets", href: "#" },
        { label: "TS-142", href: "#" },
        { label: "Modifica" }
      ]))
    end

    # Dashboard stessa: solo il root come corrente (nessun link).
    def dashboard_only
      render(Ui::BreadcrumbComponent.new(crumbs: []))
    end

    # Area valhalla: root custom.
    def valhalla_area
      render(Ui::BreadcrumbComponent.new(
        crumbs: [ { label: "Accounts" } ],
        root_href: "#",
        root_label: "Dashboard"
      ))
    end
  end
end
