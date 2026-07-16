{
  linkFarm,
  fetchzip,
  fetchgit,
}:
linkFarm "zig-packages" [
  {
    name = "known_folders-0.0.0-Fy-PJsbKAACbDh9bBxR0MMThxZSS6A9RH4apWphNHY70";
    path = fetchzip {
      url = "https://github.com/ziglibs/known-folders/archive/207c34a16e4365edc20d92c7892f962b3bed46e8.tar.gz";
      hash = "sha256-9hMnEc3ktnFTZT28hjaOkafjSUXEI+SNIO9GMcJrBfA=";
    };
  }
  {
    name = "diffz-0.0.1-G2tlISvOAQDORzPTSxDgiKwlHuADKeJMdJrw4kRfLufj";
    path = fetchzip {
      url = "https://github.com/ziglibs/diffz/archive/aac8aa99c436ab8277b0711922aad062c0167b12.tar.gz";
      hash = "sha256-GQ4iCZSSpVvdDQteoi02keLSqSoDOSQPH8eihum++Z0=";
    };
  }
  {
    name = "lsp_kit-0.1.0-bi_PLwc2DACoR7VTz_qKFXUvtx7veHvWcTQvP9pDFLpk";
    path = fetchzip {
      url = "https://github.com/zigtools/lsp-kit/archive/d148676ace1eaecf3c703ce7d350d0e94e502ed7.tar.gz";
      hash = "sha256-O4LSGT/0/2gFbXcOt0Panj4a26J5gA1NkmO0+7PfkJg=";
    };
  }
]
