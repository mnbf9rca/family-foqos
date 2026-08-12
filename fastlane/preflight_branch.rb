# frozen_string_literal: true

module PreflightBranch
  def self.mode(current_branch:, allowed_branch:)
    return :enforce_main unless current_branch.is_a?(String)
    return :enforce_main if current_branch.empty? || current_branch == 'HEAD'
    return :verification if current_branch != 'main' && allowed_branch == current_branch

    :enforce_main
  end
end
