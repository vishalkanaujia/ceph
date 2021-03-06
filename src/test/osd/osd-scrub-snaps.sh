#! /bin/bash
#
# Copyright (C) 2015 Red Hat <contact@redhat.com>
#
# Author: David Zafman <dzafman@redhat.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU Library Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library Public License for more details.
#
source $(dirname $0)/../detect-build-env-vars.sh
source $CEPH_ROOT/qa/workunits/ceph-helpers.sh

function run() {
    local dir=$1
    shift

    export CEPH_MON="127.0.0.1:7121" # git grep '\<7121\>' : there must be only one
    export CEPH_ARGS
    CEPH_ARGS+="--fsid=$(uuidgen) --auth-supported=none "
    CEPH_ARGS+="--mon-host=$CEPH_MON "

    local funcs=${@:-$(set | sed -n -e 's/^\(TEST_[0-9a-z_]*\) .*/\1/p')}
    for func in $funcs ; do
        $func $dir || return 1
    done
}

function TEST_scrub_snaps() {
    local dir=$1
    local poolname=test

    TESTDATA="testdata.$$"

    setup $dir || return 1
    run_mon $dir a --osd_pool_default_size=1 || return 1
    run_mgr $dir x || return 1
    run_osd $dir 0 || return 1

    wait_for_clean || return 1

    # Create a pool with a single pg
    ceph osd pool create $poolname 1 1
    poolid=$(ceph osd dump | grep "^pool.*[']test[']" | awk '{ print $2 }')

    dd if=/dev/urandom of=$TESTDATA bs=1032 count=1
    for i in `seq 1 15`
    do
        rados -p $poolname put obj${i} $TESTDATA
    done

    SNAP=1
    rados -p $poolname mksnap snap${SNAP}
    dd if=/dev/urandom of=$TESTDATA bs=256 count=${SNAP}
    rados -p $poolname put obj1 $TESTDATA
    rados -p $poolname put obj5 $TESTDATA
    rados -p $poolname put obj3 $TESTDATA
    for i in `seq 6 14`
     do rados -p $poolname put obj${i} $TESTDATA
    done

    SNAP=2
    rados -p $poolname mksnap snap${SNAP}
    dd if=/dev/urandom of=$TESTDATA bs=256 count=${SNAP}
    rados -p $poolname put obj5 $TESTDATA

    SNAP=3
    rados -p $poolname mksnap snap${SNAP}
    dd if=/dev/urandom of=$TESTDATA bs=256 count=${SNAP}
    rados -p $poolname put obj3 $TESTDATA

    SNAP=4
    rados -p $poolname mksnap snap${SNAP}
    dd if=/dev/urandom of=$TESTDATA bs=256 count=${SNAP}
    rados -p $poolname put obj5 $TESTDATA
    rados -p $poolname put obj2 $TESTDATA

    SNAP=5
    rados -p $poolname mksnap snap${SNAP}
    SNAP=6
    rados -p $poolname mksnap snap${SNAP}
    dd if=/dev/urandom of=$TESTDATA bs=256 count=${SNAP}
    rados -p $poolname put obj5 $TESTDATA

    SNAP=7
    rados -p $poolname mksnap snap${SNAP}

    rados -p $poolname rm obj4
    rados -p $poolname rm obj2

    kill_daemons $dir TERM osd || return 1

    # Don't need to ceph_objectstore_tool function because osd stopped

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj1)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" --force remove

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --op list obj5 | grep \"snapid\":2)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" remove

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --op list obj5 | grep \"snapid\":1)"
    OBJ5SAVE="$JSON"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" remove

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --op list obj5 | grep \"snapid\":4)"
    dd if=/dev/urandom of=$TESTDATA bs=256 count=18
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" set-bytes $TESTDATA

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj3)"
    dd if=/dev/urandom of=$TESTDATA bs=256 count=15
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" set-bytes $TESTDATA

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --op list obj4 | grep \"snapid\":7)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" remove

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj2)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" rm-attr snapset

    # Create a clone which isn't in snapset and doesn't have object info
    JSON="$(echo "$OBJ5SAVE" | sed s/snapid\":1/snapid\":7/)"
    dd if=/dev/urandom of=$TESTDATA bs=256 count=7
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" set-bytes $TESTDATA

    rm -f $TESTDATA

    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj6)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj7)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset corrupt
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj8)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset seq
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj9)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset clone_size
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj10)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset clone_overlap
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj11)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset clones
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj12)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset head
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj13)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset snaps
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj14)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" clear-snapset size

    echo "garbage" > $dir/bad
    JSON="$(ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal --head --op list obj15)"
    ceph-objectstore-tool --data-path $dir/0 --journal-path $dir/0/journal "$JSON" set-attr snapset $dir/bad
    rm -f $dir/bad

    run_osd $dir 0 || return 1
    wait_for_clean || return 1

    local pgid="${poolid}.0"
    if ! pg_scrub "$pgid" ; then
        cat $dir/osd.0.log
        return 1
    fi
    grep 'log_channel' $dir/osd.0.log

    rados list-inconsistent-pg $poolname > $dir/json || return 1
    # Check pg count
    test $(jq '. | length' $dir/json) = "1" || return 1
    # Check pgid
    test $(jq -r '.[0]' $dir/json) = $pgid || return 1

    rados list-inconsistent-snapset $pgid > $dir/json || return 1
    test $(jq '.inconsistents | length' $dir/json) = "21" || return 1

    local jqfilter='.inconsistents'
    local sortkeys='import json; import sys ; JSON=sys.stdin.read() ; ud = json.loads(JSON) ; print json.dumps(ud, sort_keys=True, indent=2)'

    jq "$jqfilter" << EOF | python -c "$sortkeys" > $dir/checkcsjson
{
  "inconsistents": [
    {
      "errors": [
        "headless"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj1"
    },
    {
      "errors": [
        "size_mismatch"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj10"
    },
    {
      "errors": [
        "headless"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj11"
    },
    {
      "errors": [
        "size_mismatch"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj14"
    },
    {
      "errors": [
        "headless"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj6"
    },
    {
      "errors": [
        "headless"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj7"
    },
    {
      "errors": [
        "size_mismatch"
      ],
      "snap": 1,
      "locator": "",
      "nspace": "",
      "name": "obj9"
    },
    {
      "errors": [
        "headless"
      ],
      "snap": 4,
      "locator": "",
      "nspace": "",
      "name": "obj2"
    },
    {
      "errors": [
        "size_mismatch"
      ],
      "snap": 4,
      "locator": "",
      "nspace": "",
      "name": "obj5"
    },
    {
      "errors": [
        "headless"
      ],
      "snap": 7,
      "locator": "",
      "nspace": "",
      "name": "obj2"
    },
    {
      "errors": [
        "oi_attr_missing",
        "headless"
      ],
      "snap": 7,
      "locator": "",
      "nspace": "",
      "name": "obj5"
    },
    {
      "extra clones": [
        1
      ],
      "errors": [
        "extra_clones"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj11"
    },
    {
      "errors": [
        "head_mismatch"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj12"
    },
    {
      "errors": [
        "ss_attr_corrupted"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj15"
    },
    {
      "extra clones": [
        7,
        4
      ],
      "errors": [
        "ss_attr_missing",
        "extra_clones"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj2"
    },
    {
      "errors": [
        "size_mismatch"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj3"
    },
    {
      "missing": [
        7
      ],
      "errors": [
        "clone_missing"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj4"
    },
    {
      "missing": [
        2,
        1
      ],
      "extra clones": [
        7
      ],
      "errors": [
        "extra_clones",
        "clone_missing"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj5"
    },
    {
      "extra clones": [
        1
      ],
      "errors": [
        "extra_clones"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj6"
    },
    {
      "extra clones": [
        1
      ],
      "errors": [
        "head_mismatch",
        "extra_clones"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj7"
    },
    {
      "errors": [
        "snapset_mismatch"
      ],
      "snap": "head",
      "locator": "",
      "nspace": "",
      "name": "obj8"
    }
  ],
  "epoch": 20
}
EOF

    jq "$jqfilter" $dir/json | python -c "$sortkeys" > $dir/csjson
    diff -y $dir/checkcsjson $dir/csjson || return 1

    if which jsonschema > /dev/null;
    then
      jsonschema -i $dir/json $CEPH_ROOT/doc/rados/command/list-inconsistent-snap.json || return 1
    fi

    for i in `seq 1 7`
    do
        rados -p $poolname rmsnap snap$i
    done

    ERRORS=0

    pidfile=$(find $dir 2>/dev/null | grep $name_prefix'[^/]*\.pid')
    pid=$(cat $pidfile)
    if ! kill -0 $pid
    then
        echo "OSD crash occurred"
        tail -100 $dir/osd.0.log
        ERRORS=$(expr $ERRORS + 1)
    fi

    kill_daemons $dir || return 1

    declare -a err_strings
    err_strings[0]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*::obj10:.* is missing in clone_overlap"
    err_strings[1]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*::obj5:7 no '_' attr"
    err_strings[2]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*::obj5:7 is an unexpected clone"
    err_strings[3]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*::obj5:4 on disk size [(]4608[)] does not match object info size [(]512[)] adjusted for ondisk to [(]512[)]"
    err_strings[4]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj5:head expected clone .*:::obj5:2"
    err_strings[5]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj5:head expected clone .*:::obj5:1"
    err_strings[6]="log_channel[(]cluster[)] log [[]INF[]] : scrub [0-9]*[.]0 .*:::obj5:head 2 missing clone[(]s[)]"
    err_strings[7]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj12:head snapset.head_exists=false, but head exists"
    err_strings[8]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj8:head snaps.seq not set"
    err_strings[9]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj7:head snapset.head_exists=false, but head exists"
    err_strings[10]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj7:1 is an unexpected clone"
    err_strings[11]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj3:head on disk size [(]3840[)] does not match object info size [(]768[)] adjusted for ondisk to [(]768[)]"
    err_strings[12]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj6:1 is an unexpected clone"
    err_strings[13]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj2:head no 'snapset' attr"
    err_strings[14]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj2:7 clone ignored due to missing snapset"
    err_strings[15]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj2:4 clone ignored due to missing snapset"
    err_strings[16]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj4:head expected clone .*:::obj4:7"
    err_strings[17]="log_channel[(]cluster[)] log [[]INF[]] : scrub [0-9]*[.]0 .*:::obj4:head 1 missing clone[(]s[)]"
    err_strings[18]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj1:1 is an unexpected clone"
    err_strings[19]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj9:1 is missing in clone_size"
    err_strings[20]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj11:1 is an unexpected clone"
    err_strings[21]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj14:1 size 1032 != clone_size 1033"
    err_strings[22]="log_channel[(]cluster[)] log [[]ERR[]] : [0-9]*[.]0 scrub 23 errors"
    err_strings[23]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj15:head can't decode 'snapset' attr buffer"
    err_strings[24]="log_channel[(]cluster[)] log [[]ERR[]] : scrub [0-9]*[.]0 .*:::obj12:1 has no oi or legacy_snaps; cannot convert 1=[[]1[]]:[[]1[]].stray_clone_snaps=[{]1=[[]1[]][}]"

    for i in `seq 0 ${#err_strings[@]}`
    do
        if ! grep "${err_strings[$i]}" $dir/osd.0.log > /dev/null;
        then
            echo "Missing log message '${err_strings[$i]}'"
            ERRORS=$(expr $ERRORS + 1)
        fi
    done

    teardown $dir || return 1

    if [ $ERRORS != "0" ];
    then
        echo "TEST FAILED WITH $ERRORS ERRORS"
        return 1
    fi

    echo "TEST PASSED"
    return 0
}

main osd-scrub-snaps "$@"

# Local Variables:
# compile-command: "cd ../.. ; make -j4 && \
#    test/osd/osd-scrub-snaps.sh"
