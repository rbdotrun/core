# frozen_string_literal: true

require "test_helper"

class LocalGitTest < Minitest::Test
  def test_current_branch_returns_string
    # We're running in a git repo (this project), so it should work
    branch = RbrunCore::LocalGit.current_branch

    assert_kind_of String, branch
    refute_empty branch
  end

  def test_repo_from_remote_extracts_ssh_url
    RbrunCore::LocalGit.stub(:`, "git@github.com:myorg/myapp.git\n") do
      assert_equal "myorg/myapp", RbrunCore::LocalGit.repo_from_remote
    end
  end

  def test_repo_from_remote_extracts_https_url
    RbrunCore::LocalGit.stub(:`, "https://github.com/myorg/myapp.git\n") do
      assert_equal "myorg/myapp", RbrunCore::LocalGit.repo_from_remote
    end
  end

  def test_repo_from_remote_handles_no_dot_git_suffix
    RbrunCore::LocalGit.stub(:`, "https://github.com/myorg/myapp\n") do
      assert_equal "myorg/myapp", RbrunCore::LocalGit.repo_from_remote
    end
  end

  def test_gh_auth_token_raises_when_empty
    RbrunCore::LocalGit.stub(:`, "") do
      assert_raises(RbrunCore::Error) { RbrunCore::LocalGit.gh_auth_token }
    end
  end
end
