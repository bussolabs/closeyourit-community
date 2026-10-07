# frozen_string_literal: true

module Ui
  class UserMenuComponentPreview < ViewComponent::Preview
    # Header member: trigger col nome + voce Account + Esci.
    def member
      render(Ui::UserMenuComponent.new(
               name: "Ada Lovelace",
               account_path: "#",
               account_label: "Account",
               logout_path: "#",
               trigger_test_id: "member-user-menu",
               account_test_id: "member-nav-preferences",
               logout_test_id: "logout"
             ))
    end

    # Header member per un god: Account + ingresso Valhalla (corona, dopo divider) + Esci.
    def member_god
      render(Ui::UserMenuComponent.new(
               name: "Zeus",
               account_path: "#",
               account_label: "Account",
               valhalla_path: "#",
               valhalla_label: "Valhalla · God mode",
               valhalla_test_id: "member-nav-valhalla",
               logout_path: "#",
               trigger_test_id: "member-user-menu",
               account_test_id: "member-nav-preferences",
               logout_test_id: "logout"
             ))
    end

    # Header valhalla (god): solo nome + Esci.
    def valhalla
      render(Ui::UserMenuComponent.new(
               name: "god@example.com",
               logout_path: "#",
               trigger_test_id: "valhalla-user-menu",
               logout_test_id: "valhalla-logout"
             ))
    end
  end
end
