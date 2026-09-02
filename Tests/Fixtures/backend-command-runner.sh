#!/bin/bash
set -u

case "${1:-}" in
  normal)
    printf 'normal-output\n'
    ;;
  hang)
    /bin/bash -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
    wait
    ;;
  partial-hang)
    printf '===== 1. 部分结果 =====\n  ✅ 已完成项目\n'
    /bin/bash -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
    wait
    ;;
  *)
    exit 2
    ;;
esac
