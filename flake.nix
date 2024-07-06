{
  description = "InvokeAI is a leading creative engine for Stable Diffusion models, empowering professionals, artists, and enthusiasts to generate and create visual media using the latest AI-driven technologies. The solution offers an industry leading WebUI, supports terminal use through a CLI, and serves as the foundation for multiple commercial products. ";

  # TODO: add a cuda enabled shell and make default without cuda

  nixConfig = {
    extra-substituters = [
      "https://ai.cachix.org"
      "https://cuda-maintainers.cachix.org"
    ];
    extra-trusted-public-keys = [
      "ai.cachix.org-1:N9dzRK+alWwoKXQlnn0H6aUx0lU/mspIoz8hMvGvbbc="
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";

    poetry2nix.url = "github:nix-community/poetry2nix";
    poetry2nix.inputs.nixpkgs.follows = "nixpkgs";

    pnpm2nix.url = "github:nzbr/pnpm2nix-nzbr";
    pnpm2nix.inputs.nixpkgs.follows = "nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... } @rawInputs:
    let
      systems = flake-utils.lib.defaultSystems;
    in
    builtins.foldl'
      (outputs: system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlay = [ poetry2nix.overlay ];
            config = {
              allowUnfree = true;
              cudaSupport = true;
            };
          };

          poetry2nix = (rawInputs.poetry2nix.lib.mkPoetry2Nix { inherit pkgs; });

          postPatchWheel = postPatch: ''
            cd dist
            ls -la
            whl="$(basename ./*.whl)"
            unzip $whl
            rm $whl
          '' + postPatch + ''
            ls -la .
            zip -r ../$whl ./*
            cd ..
            rm -fr dist
            mkdir dist
            mv $whl dist
          '';

          pypkgs-build-requirements = {
            requests-testadapter = [ "setuptools" ];
            opentelemetry-util-http = [ "opentelemetry-semantic-conventions" "deprecated" ];

            # FIXME: for some reason these three check for runtime dependencies in a different way
            llama-index-core = [ "requests" ];
            llama-index-legacy = [ "requests" ];
            opentelemetry-exporter-otlp-proto-grpc = [ "opentelemetry-sdk" ];
            myst-parser = [ "markdown-it-py" ];
          };

          env = poetry2nix.mkPoetryEnv {
            projectDir = ./.;
            preferWheels = true;
            # extras = [ "xformers" "onnx" "onnx-cuda" ];
            extras = [ ];
            editablePackageSources = {
              invokeai = ./invokeai;
            };
            overrides = poetry2nix.defaultPoetryOverrides.extend
              (final: prev:
                (builtins.mapAttrs
                  (package: build-requirements:
                    (builtins.getAttr package prev).overridePythonAttrs (old: {
                      buildInputs = (old.buildInputs or [ ])
                      ++ (builtins.map
                        (pkg:
                          if builtins.isString pkg
                          then builtins.getAttr pkg prev
                          else pkg)
                        build-requirements);
                    }))
                  pypkgs-build-requirements) //
                {
                  windows-curses = null;

                  pyright = prev.pyright.overridePythonAttrs (old: {
                    postInstall = (old.postInstall or "") + ''
                      wrapProgram $out/bin/pyright \
                        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nodejs ]}
                      wrapProgram $out/bin/pyright-langserver \
                        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nodejs ]}
                    '';
                  });

                  onnxruntime-gpu = prev.torch.overridePythonAttrs (old: {
                    buildInputs = (old.buildInputs or [ ]) ++ (with pkgs; [
                      cudaPackages.cudnn
                      cudaPackages.cuda_cudart
                    ]);
                  });

                  torch = prev.torch.overridePythonAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                      pkgs.autoPatchelfHook
                      pkgs.addDriverRunpath
                    ];
                    buildInputs = (old.buildInputs or [ ]) ++ (with pkgs; [
                      cudaPackages.cudnn
                      cudaPackages.cuda_nvrtc
                      cudaPackages.nccl
                      cudaPackages.cuda_cudart
                    ]);
                    extraRunpaths = [ "${prev.lib.getLib pkgs.cudaPackages.cuda_nvrtc}/lib" ];
                    postPhases = prev.lib.optionals pkgs.stdenv.hostPlatform.isUnix [ "postPatchelfPhase" ];
                    postPatchelfPhase = ''
                      while IFS= read -r -d $'\0' elf ; do
                        for extra in $extraRunpaths ; do
                          echo patchelf "$elf" --add-rpath "$extra" >&2
                          patchelf "$elf" --add-rpath "$extra"
                        done
                      done < <(
                        find "''${!outputLib}" "$out" -type f -iname '*.so' -print0
                      )
                    '';
                  });

                  torchvision = prev.torchvision.overridePythonAttrs (old: {
                    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                      pkgs.autoPatchelfHook
                    ];
                  });

                  opencv-python-headless = prev.opencv-python-headless.overridePythonAttrs (_old: {
                    postInstall = ''
                      # Conflicts with same files from `opencv-python`
                      rm -rf $out/lib/python3.11/site-packages/cv2
                    '';
                  });
                  opencv-contrib-python = prev.opencv-contrib-python.overridePythonAttrs (_old: {
                    postInstall = ''
                      # Conflicts with same files from `opencv-python`
                      rm -rf $out/lib/python3.11/site-packages/cv2
                    '';
                  });

                  # FIXME: this probably doesn't work
                  # NOTE: https://github.com/nix-community/poetry2nix/issues/733#issuecomment-1264334597
                  # NOTE: https://github.com/nix-community/poetry2nix/issues/731#issuecomment-1260669209
                  # NOTE: https://github.com/pyca/bcrypt/blob/4.1.3/src/_bcrypt/Cargo.lock
                  bcrypt = prev.bcrypt.overridePythonAttrs (old: {
                    nativeBuildInputs = (old.buildInputs or [ ]) ++ [ pkgs.unzip pkgs.zip ];
                    unpackPhase = ''
                      echo "Executing unpackPhase"
                      runHook preUnpack
                      mkdir -p dist
                      cp "$src" "dist/$(stripHash "$src")"
                      runHook cargoSetupPostUnpackHook
                      cd dist
                      ls -la
                      whl="$(basename ./*.whl)"
                      unzip $whl
                      rm $whl
                      runHook cargoSetupPostPatchHook
                      ls -la .
                      zip -r ../$whl ./*
                      cd ..
                      rm -fr dist
                      mkdir dist
                      mv $whl dist
                      echo "Finished executing unpackPhase"
                    '';
                    patchPhase = "";
                  });

                  # FIXME: these are wrong but doesn't work without it
                  # NOTE: should try adding as dependencies
                  opentelemetry-exporter-otlp-proto-grpc = prev.opentelemetry-exporter-otlp-proto-grpc.overridePythonAttrs (old: {
                    buildInputs = (old.buildInputs or [ ]) ++ (with pkgs; [
                      python311Packages.opentelemetry-sdk
                    ]);
                  });
                  myst-parser = prev.myst-parser.overridePythonAttrs (old: {
                    buildInputs = (old.buildInputs or [ ]) ++ (with pkgs; [
                      python311Packages.markdown-it-py
                    ]);
                  });
                  llama-index-core = prev.llama-index-core.overridePythonAttrs (old: {
                    buildInputs = (old.buildInputs or [ ]) ++ (with pkgs; [
                      python311Packages.requests
                    ]);
                  });
                  llama-index-legacy = prev.llama-index-legacy.overridePythonAttrs (old: {
                    buildInputs = (old.buildInputs or [ ]) ++ (with pkgs; [
                      python311Packages.requests
                    ]);
                  });
                });
          };

          mkEnvWrapper = name: pkgs.writeShellApplication {
            name = name;
            runtimeInputs = [ env ];
            text = ''
              export PYTHONPREFIX=${env}
              export PYTHONEXECUTABLE=${env}/bin/python

              # shellcheck disable=SC2125
              export PYTHONPATH=${env}/lib/**/site-packages

              ${name} "$@"
            '';
          };
        in
        outputs // {
          devShells.${system}.default = pkgs.mkShell {
            packages = with pkgs; [
              # Nix
              nil
              nixpkgs-fmt

              # Python
              poetry
              (mkEnvWrapper "pyright")
              (mkEnvWrapper "pyright-langserver")
              env

              # Misc
              nodePackages.prettier
              nodePackages.yaml-language-server
              nodePackages.vscode-json-languageserver
              marksman
              taplo

              # Tools
              nushell
              just
            ];
          };
        })
      { }
      systems;
}
