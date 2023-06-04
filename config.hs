-- This is the main configuration file for Propellor, and is used to build
-- the propellor program.    https://propellor.branchable.com/
{-# LANGUAGE DataKinds #-}

import Base (OS)
import Cardano (setupNode)
import Propellor
import Propellor.Base (combineModes, liftIO)
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.Cron as Cron
import qualified Propellor.Property.File as File
import Propellor.Property.Firewall (Chain (..), ConnectionState (..), Proto (..), Rules (..), Table (..), Target (..), rule)
import qualified Propellor.Property.Firewall as Firewall
import qualified Propellor.Property.Git as Git
import qualified Propellor.Property.LetsEncrypt as LetsEncrypt
import qualified Propellor.Property.Nginx as Nginx
import qualified Propellor.Property.Ssh as Ssh
import qualified Propellor.Property.Sudo as Sudo
import qualified Propellor.Property.Systemd as Systemd
import qualified Propellor.Property.Tor as Tor
import qualified Propellor.Property.User as User
import Propellor.Types.MetaTypes (MetaType (..), MetaTypes)
import Propellor.Utilities (doesFileExist, readProcess)
import System.Posix (ownerExecuteMode, ownerReadMode, ownerWriteMode)

main :: IO ()
main = defaultMain hosts

-- The hosts propellor knows about.
hosts :: [Host]
hosts = [clermont, cardano]

letsEncryptAgree :: LetsEncrypt.AgreeTOS
letsEncryptAgree = LetsEncrypt.AgreeTOS (Just "me@punkachien.net")

basePackages :: [String]
basePackages =
    [ "etckeeper"
    , "ssh"
    , "jq"
    , "tmux"
    , "dstat"
    , "git"
    , "emacs-nox"
    , "silversearcher-ag"
    , "direnv"
    , "python3-pip"
    ]

clermont :: Host
clermont =
    host "clermont" $ do
        props
            & osDebian Unstable X86_64
            & Ssh.authorizedKeys root hostContext
            & Apt.stdSourcesList
            & Apt.unattendedUpgrades
            & Apt.installed basePackages
            & installNix
            & File.hasContent "/etc/nix/nix.conf" nixConf
            & Systemd.started "nix-daemon.service"
            & Ssh.installed
            & Systemd.persistentJournal
            & setupUser user
            & setupNode user
            & File.dirExists "/var/www"
            & File.ownerGroup "/var/www" user userGrp
            & Nginx.siteEnabled "www.punkachien.net" punkachien
            & LetsEncrypt.letsEncrypt letsEncryptAgree "www.punkachien.net" "/var/www/punkachien.net/public_html"
            `requires` letsEncryptNginxConf
            `onChange` Nginx.reloaded
            & Nginx.siteEnabled "jupyter.mithril.network" jupyter
            & LetsEncrypt.letsEncrypt letsEncryptAgree "jupyter.mithril.network" "/var/www/jupyter.mithril.network/public_html"
              `requires` File.dirExists "/var/www/jupyter.mithril.network/public_html"
              `requires` letsEncryptNginxConf
              `onChange` Nginx.reloaded
            & installRust
  where
    root = User "root"
    user = User "curry"
    userGrp = Group "curry"
    nixGrp = Group "nixbld"
    systemdJournal = Group "systemd-journal"

    setupUser u =
        propertyList ("Configured user " <> show u) $
            props
                & User.accountFor u
                & Ssh.authorizedKey user ""
                & Ssh.authorizedKeys user hostContext
                & Ssh.userKeyAt
                    Nothing
                    user
                    hostContext
                    ( SshEd25519
                    , "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIERjBICdoL0S4dU+HgevTutHF0QajK/qEN1iHKgeU7+T Remote curry user's key"
                    )
                & User.hasGroup u nixGrp
                & User.hasGroup u systemdJournal
                & Git.cloned user "git@github.com:abailly-iohk/dotfiles" "/home/curry/dotfiles" Nothing
                & File.hasContent "/home/curry/sensei/hooks/update" senseiUpdateHook
                `requires` stackInstalled
                `requires` Git.bareRepo "sensei" user Git.NotShared
                `onChange` ( "/home/curry/sensei/hooks/update"
                                `File.mode` combineModes [ownerReadMode, ownerWriteMode, ownerExecuteMode]
                           )
                `onChange` File.ownerGroup "/home/curry/sensei/hooks/update" user userGrp
                & Sudo.enabledFor u
                & File.hasPrivContent "/home/curry/.config/sensei/client.json" anyContext
                `requires` File.dirExists "/home/curry/.config/sensei/"
                `requires` File.applyPath "/home/curry/.config" "sensei/client.json" (\f -> File.ownerGroup f u userGrp)

    senseiUpdateHook =
        [ "#!/bin/sh"
        , "echo \"Updating $1 from $2 to $3\""
        ]

    nixConf =
        [ "max-jobs = 6"
        , "cores = 0"
        , "trusted-users = root curry"
        , "keep-derivations = true"
        , "keep-outputs = true"
        , "experimental-features = nix-command flakes"
        , "substituters = https://cache.nixos.org https://hydra.iohk.io https://iohk.cachix.org https://cache.iog.io https://cardano-scaling.cachix.org https://cache.zw3rk.com"
        , "trusted-public-keys = iohk.cachix.org-1:DpRUyj7h7V830dp/i6Nti+NEO2/nhblbov/8MW7Rqoo= hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= cardano-scaling.cachix.org-1:RKvHKhGs/b6CBDqzKbDk0Rv6sod2kPSXLwPzcUQg9lY= loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
        ]

    installRust =
        check
            doesNotHaveRust
            ( scriptProperty
                [ "curl -sSf https://sh.rustup.rs | sudo RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust sh -s -- --no-modify-path -y"
                , "echo 'export RUSTUP_HOME=/opt/rust' | sudo tee -a /etc/profile.d/rust.sh"
                , "echo 'export PATH=$PATH:/opt/rust/bin' | sudo tee -a /etc/profile.d/rust.sh"
                ]
            )
            `requires` Apt.installed ["gcc", "build-essential", "m4", "pkgconf", "libssl-dev"]
            `describe` "Rustup toolchain installed"

    doesNotHaveRust =
        not <$> doesFileExist "/opt/rust/bin/rustc"

    shouldInstallNix =
        not . ("2.15.0" `elem`) . words <$> readProcess "/nix/var/nix/profiles/default/bin/nix" ["--version"]

    installNix =
        check
            shouldInstallNix
            ( scriptProperty
                [ "curl -o install-nix-2.15.0 https://releases.nixos.org/nix/nix-2.15.0/install"
                , "chmod +x ./install-nix-2.15.0"
                , "./install-nix-2.15.0 --daemon < /dev/null"
                ]
            )
            `describe` "Nix 2.15.0 installed"

    stackInstalled =
        check
            shouldInstallStack
            ( scriptProperty
                [ "curl -o install-stack -sSL https://get.haskellstack.org/"
                , "/bin/sh install-stack -d /usr/local/bin"
                ]
            )
            `describe` "Stack 2.11.1 installed"

    shouldInstallStack = do
        hasStack <- doesFileExist "/usr/local/bin/stack"
        if hasStack
            then not . ("2.11.1," `elem`) . words <$> readProcess "/usr/local/bin/stack" ["--version"]
            else pure True

    -- for some reason, let's encrypt does not install this conf file
    letsEncryptNginxConf =
        check
            (not <$> doesFileExist "/etc/letsencrypt/options-ssl-nginx.conf")
            ( scriptProperty
                [ "curl -o /etc/letsencrypt/options-ssl-nginx.conf https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf"
                ]
            )
            `describe` "Let's Encrypt Nginx configured"

    punkachien =
        [ "server {"
        , "    listen 80;"
        , "    listen [::]:80;"
        , "    "
        , "    root /var/www/punkachien.net/public_html;"
        , "    index index.html index.htm index.nginx-debian.html;"
        , "    "
        , "    server_name www.punkachien.net punkachien.net;"
        , "    "
        , "    listen 443 ssl; # managed by Certbot"
        , ""
        , "    # RSA certificate"
        , "    ssl_certificate /etc/letsencrypt/live/www.punkachien.net/fullchain.pem; # managed by Certbot"
        , "    ssl_certificate_key /etc/letsencrypt/live/www.punkachien.net/privkey.pem; # managed by Certbot"
        , ""
        , "    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot"
        , ""
        , "    # Redirect non-https traffic to https"
        , "    if ($scheme != \"https\") {"
        , "        return 301 https://$host$request_uri;"
        , "    } # managed by Certbot"
        , ""
        , "    location / {"
        , "            try_files $uri $uri/ =404;"
        , "    }"
        , "}"
        ]

    jupyter =
        [
          "          server {"
        , "    listen 80;"
        , "    listen [::]:80;"
        , "    server_name jupyter.mithril.network;"
        , "    location / {"
        , "            rewrite ^ https://$host$request_uri? permanent;"
        , "    }"
        , "    location ~ /.well-known/acme-challenge {"
        , "        allow all;"
        , "        root /var/www/jupyter.mithril.network/public_html;"
        , "    }"
        , "}"
        , "server {"
        , "    server_name jupyter.mithril.network;"
        , "    "
        , "    listen 443 ssl; # managed by Certbot"
        , ""
        , "    # RSA certificate"
        , "    ssl_certificate /etc/letsencrypt/live/jupyter.mithril.network/fullchain.pem; # managed by Certbot"
        , "    ssl_certificate_key /etc/letsencrypt/live/jupyter.mithril.network/privkey.pem; # managed by Certbot"
        , ""
        , "    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot"
        , ""
        , "    location / {"
        , "        proxy_pass http://127.0.0.1:8888;"
        , "        proxy_set_header X-Real-IP $remote_addr;"
        , "        proxy_set_header Host $host;"
        , "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
        , ""
        , "        # websocket headers"
        , "        proxy_http_version 1.1;"
        , "        proxy_set_header Upgrade $http_upgrade;"
        , "        proxy_set_header Connection $connection_upgrade;"
        , "        proxy_set_header X-Scheme $scheme;"
        , ""
        , "        proxy_buffering off;"
        , "    }"
        , "}"
        ]

cardano :: Host
cardano =
    host "cardano.hydra.bzh" $
        props
            & osDebian Unstable X86_64
            & Apt.stdSourcesList
            & Apt.unattendedUpgrades
            & Apt.installed ["etckeeper"]
            & Apt.installed ["ssh", "jq", "tmux", "dstat"]
            & Ssh.installed
            & Tor.installed
            & Tor.hiddenServiceAvailable "ssh" (Port 22)
            & User.hasSomePassword (User "root")
            & File.dirExists "/var/www"
            & Cron.runPropellor (Cron.Times "30 * * * *")
            & Systemd.persistentJournal
            & firewall
            & setupNode user
            & setupHydraNode
  where
    user = User "curry"

firewall :: Property OS
firewall =
    propertyList "firewall accepts ssh and Cardano relay " $
        props
            & flush INPUT
            & firewallPreamble
            & Firewall.rule INPUT Filter ACCEPT (Proto TCP :- DPort (Port 22))
            & Firewall.rule INPUT Filter ACCEPT (Proto TCP :- DPort (Port 3001))
            & Firewall.rule INPUT Filter ACCEPT (Proto TCP :- DPort (Port 5001))
            & dropEverything

setupHydraNode :: Property (MetaTypes '[ 'Targeting 'OSDebian, 'Targeting 'OSBuntish, 'Targeting 'OSArchLinux])
setupHydraNode =
    propertyList "Cardano node" $
        props
            & File.hasContent "/home/curry/hydra-node.environment" envFile
            & File.hasContent "/etc/systemd/system/hydra-node.service" serviceFile
            & Systemd.enabled "hydra-node"
            & Systemd.started "hydra-node"
  where
    envFile =
        [ "SOCKETPATH=/home/curry/node.socket"
        , "HYDRA_SCRIPTS_TX_ID=4a4f3e25887b40f1575a4b53815996145c994559bac1b5d85f7de0f82b8f4ed5"
        ]

    serviceFile =
        [ "[Unit]"
        , "Description=Hydra node"
        , "After=multi-user.target"
        , ""
        , "[Service]"
        , "Type=simple"
        , "EnvironmentFile=/home/curry/hydra-node.environment"
        , "ExecStart=/home/curry/run-hydra.sh"
        , "KillSignal = SIGINT"
        , "RestartKillSignal = SIGINT"
        , "StandardOutput=journal"
        , "StandardError=journal"
        , "SyslogIdentifier=hydra-node"
        , ""
        , "LimitNOFILE=32768"
        , ""
        , "Restart=on-failure"
        , "RestartSec=15s"
        , "StartLimitIntervalSec=0"
        , "WorkingDirectory=~"
        , "User=curry"
        , "Group=curry"
        , ""
        , "[Install]"
        , "WantedBy=multi-user.target"
        ]

{- | A basic rule to drop every input packet

 This should be used as last clause for a bunch of rules, like:
-}
dropEverything :: Property Linux
dropEverything = rule INPUT Filter DROP Everything

{- | Drop all rules for given chain.

 Useful at start of configuration of firewall rules
-}
flush :: Chain -> Property OS
flush chain =
    property ("flushing all rules for chain " <> show chain) $
        liftPropellor $
            toResult <$> boolSystem "iptables" (map Param ["-F", show chain])

firewallPreamble :: Property (MetaTypes '[ 'Targeting 'OSDebian, 'Targeting 'OSBuntish])
firewallPreamble =
    propertyList "standard firewall preamble rules (opens lo and docker0)" $
        props
            & Firewall.installed
            & Firewall.rule INPUT Filter ACCEPT (Ctstate [ESTABLISHED, RELATED])
            & Firewall.rule INPUT Filter ACCEPT (InIFace "lo")
