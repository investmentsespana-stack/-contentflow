# Stable Certification Receipt Checklist

A Stable receipt is valid only when all of the following are true:

- the workflow event is `push`;
- the ref is `refs/heads/main`;
- `director-certification` succeeded;
- the complete `browser-matrix` succeeded;
- the commit status context is exactly `contentflow/stable-recertification`;
- the published state is `success`.

If any prerequisite fails, no green Stable receipt may be published.
