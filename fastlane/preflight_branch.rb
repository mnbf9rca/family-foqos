# frozen_string_literal: true

module PreflightBranch
  def self.mode(current_branch:, allowed_branch:)
    return :verification if current_branch != 'main' && allowed_branch == current_branch

    :enforce_main
  end
end
