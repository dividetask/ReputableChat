# frozen_string_literal: true

# 9393 by default rather than puma's 9292, which the chat uses: the two run
# side by side, and each announces its own address -- this one on the host
# account's identity declaration, the chat on its service notice.
port ENV.fetch("PORT", 9393)
