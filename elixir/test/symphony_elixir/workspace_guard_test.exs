defmodule SymphonyElixir.WorkspaceGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkspaceGuard

  test "workspace guard keeps local agent cwd inside the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-2")

      File.mkdir_p!(workspace)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = WorkspaceGuard.validate(workspace, nil)
      assert canonical_workspace == Path.expand(workspace)

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               WorkspaceGuard.validate(workspace_root, nil)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               WorkspaceGuard.validate(outside_workspace, nil)

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               WorkspaceGuard.validate(symlink_workspace, nil)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace guard reports unreadable local cwd paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-guard-unreadable-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      blocking_file = Path.join(workspace_root, "MT-3")

      File.mkdir_p!(workspace_root)
      File.write!(blocking_file, "not a directory")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, _path, _reason}} =
               WorkspaceGuard.validate(Path.join(blocking_file, "nested"), nil)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace guard validates remote worker cwd values without local path checks" do
    assert {:ok, "/srv/symphony/MT-1"} = WorkspaceGuard.validate("/srv/symphony/MT-1", "worker-a")

    assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "worker-a"}} =
             WorkspaceGuard.validate("   ", "worker-a")

    assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, "worker-a", _workspace}} =
             WorkspaceGuard.validate("/srv/symphony\nMT-1", "worker-a")

    assert {:error, {:invalid_workspace_cwd, :invalid_workspace}} =
             WorkspaceGuard.validate(nil, nil)
  end
end
