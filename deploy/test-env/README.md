# Legacy test-env assets

`bootstrap.sh` has been removed. Test and production hosts are now managed through
the production control-plane CLI:

```bash
cd deploy/production
./install_ctl.sh
myapp-ctl deploy --build   # build from local source on a lab host
myapp-ctl deploy --pull    # pull Docker Hub images on a clean host
```

Useful component-level commands:

```bash
myapp-ctl deploy --plan
myapp-ctl deploy --group infra --pull
myapp-ctl deploy --group agent --pull
myapp-ctl deploy --group core --pull
myapp-ctl deploy backend --pull
myapp-ctl restart backend
myapp-ctl log backend -f -n 120
```

This directory is kept only for legacy compose/template reference while OpenIM
and Supabase deployment are folded into `myapp-ctl`.
