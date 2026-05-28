.PHONY: test sync-test-suite

test:
	zig build test
	zig build test-suite

# Sync tests/test_cases with the latest official KDL test suite from kdl-org/kdl.
# Replaces the whole tests/test_cases directory and prints the upstream revision.
sync-test-suite:
	@tmp=$$(mktemp -d) && \
	git clone --depth 1 https://github.com/kdl-org/kdl.git $$tmp >/dev/null 2>&1 && \
	rm -rf tests/test_cases && \
	cp -r $$tmp/tests/test_cases tests/test_cases && \
	rev=$$(git -C $$tmp rev-parse --short HEAD) && \
	rm -rf $$tmp && \
	echo "Synced tests/test_cases to kdl-org/kdl @ $$rev"
