# Copyright (C) 2021 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.
#
# Summary: sssd test with 389-ds as provider
#
# Set up 389-ds in container and run test cases below:
# 1. nss_sss test: look up user identity with id: uid and gid
# 2. pam_sss test: ssh login localhost as remote user.
# 3. write permission test: change remote user password with passwd
# 4. sssd-sudo test: Sudo run command as another remote user with sudoers rules defined in server
# 5. offline test: shutdown server, run test cases above again
#
# Detailed testcases: https://bugzilla.suse.com/tr_show_case.cgi?case_id=1768710
#
# Maintainer: Tony Yuan <tyuan@suse.com>

package sssd_389ds_functional;
use base 'consoletest';
use testapi;
use strict;
use warnings;
use utils;
use version_utils;
use registration 'add_suseconnect_product';

sub run {
    #my ($self) = @_;
    #$self->select_serial_terminal;  #uncomment this test will run in serial console
    select_console("root-console");
    my $docker = "podman";
    if (!get_var("SSSD_389DS_FUNCTIONAL_SETUP")) {
        if (is_sle) {
            $docker = "docker";
            add_suseconnect_product('PackageHub', undef, undef, undef, 300, 1);
            is_sle('<15') ? add_suseconnect_product("sle-module-containers", 12) : add_suseconnect_product("sle-module-containers");
        }
        zypper_call("in sssd sssd-ldap openldap2-client sshpass $docker");

        #Select container base image by specifying variable BASE_IMAGE_TAG. (for sles using sle15sp3 by default).
        my $pkgs = "systemd systemd-sysvinit 389-ds openssl";
        my $tag  = get_var("BASE_IMAGE_TAG");
        unless ($tag) {
            if (is_opensuse) { $tag = (is_tumbleweed) ? "registry.opensuse.org/opensuse/tumbleweed" : "registry.opensuse.org/opensuse/leap";
            } else           { $tag = "registry.suse.com/suse/sle15:15.3"; }
        }
        systemctl("enable --now $docker") if ($docker eq "docker");
        # build image, create container, setup 389-ds database and import testing data
        assert_script_run("mkdir /tmp/sssd && cd /tmp/sssd");
        assert_script_run("curl " . "--remote-name-all " . data_url("sssd/398-ds/{user_389.ldif,access.ldif,Dockerfile_$docker,instance_389.inf}"));
        assert_script_run(qq($docker build -t ds389_image --build-arg tag="$tag" --build-arg pkgs="$pkgs" -f Dockerfile_$docker .), timeout => 600);
        assert_script_run("$docker run -itd --name ds389_container --hostname ldapserver --privileged -v /sys/fs/cgroup:/sys/fs/cgroup:ro --restart=always ds389_image") if ($docker eq "docker");
        assert_script_run("$docker run -itd --name ds389_container --hostname ldapserver ds389_image") if ($docker eq "podman");
        assert_script_run("$docker exec ds389_container sed -n '/ldapserver/p' /etc/hosts >> /etc/hosts");
        assert_script_run("$docker exec ds389_container dscreate from-file /tmp/instance_389.inf");
        assert_script_run('ldapadd -x -H ldap://ldapserver -D "cn=Directory Manager" -w opensuse -f user_389.ldif');
        assert_script_run('ldapadd -x -H ldap://ldapserver -D "cn=Directory Manager" -w opensuse -f access.ldif');

        # Configure sssd on the host side
        assert_script_run("$docker cp ds389_container:/etc/dirsrv/slapd-frist389/ca.crt /etc/sssd/ldapserver.crt");
        assert_script_run("curl " . data_url("sssd/398-ds/sssd.conf") . " -o /etc/sssd/sssd.conf");
        assert_script_run("curl " . data_url("sssd/398-ds/nsswitch.conf") . " -o /etc/nsswitch.conf");
        assert_script_run("curl " . data_url("sssd/398-ds/config") . " --create-dirs -o ~/.ssh/config");
        systemctl("disable --now nscd.service");
        systemctl("enable --now sssd.service");
        set_var("SSSD_389DS_FUNCTIONAL_SETUP", 1);
    }

    #execute test cases
    #get remote user indentity
    validate_script_output("id alice", sub { m/uid=9998\(alice\)/ });
    #remote user authentification test
    assert_script_run("pam-config -a --sss --mkhomedir");
    validate_script_output('sshpass -p open5use ssh mary@localhost whoami', sub { m/mary/ });
    #Change password of remote user
    assert_script_run('sshpass -p open5use ssh alice@localhost \'echo -e "open5use\nn0vell88\nn0vell88" | passwd\'');
    validate_script_output('sshpass -p n0vell88 ssh alice@localhost echo "login as new password!"', sub { m/new password/ });
    validate_script_output('ldapwhoami -x -H ldap://ldapserver -D uid=alice,ou=users,dc=sssdtest,dc=com -w n0vell88', sub { m/alice/ }); #verify password changed in remote 389-ds.
                                                                                                                                         #Sudo run a command as another user
    assert_script_run("sed -i '/Defaults targetpw/s/^/#/' /etc/sudoers");
    validate_script_output('sshpass -p open5use ssh mary@localhost "echo open5use|sudo -S -l"', sub { m#/usr/bin/cat# });
    assert_script_run(qq(su -c 'echo "file read only by owner alice" > hello && chmod 600 hello' -l alice));
    validate_script_output('sshpass -p open5use ssh mary@localhost "echo open5use|sudo -S -u alice /usr/bin/cat /home/alice/hello"', sub { m/file read only by owner alice/ });
    #Change back password of remote user
    assert_script_run('sshpass -p n0vell88 ssh alice@localhost \'echo -e "n0vell88\nopen5use\nopen5use" | passwd\'');
    validate_script_output('sshpass -p open5use ssh alice@localhost echo "Password changed back!"', sub { m/Password changed back/ });

    #offline identity lookup and authentification
    assert_script_run("$docker stop ds389_container") if ($docker eq "docker");
    #offline cached remote user indentity lookup
    validate_script_output("id alice", sub { m/uid=9998\(alice\)/ });
    #offline remote user authentification test
    validate_script_output('sshpass -p open5use ssh mary@localhost whoami', sub { m/mary/ });
    #offline sudo run a command as another user
    validate_script_output('sshpass -p open5use ssh mary@localhost "echo open5use|sudo -S -u alice /usr/bin/cat /home/alice/hello"', sub { m/file read only by owner alice/ });
}

1;
