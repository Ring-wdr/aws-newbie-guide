# aws-emulator 컨테이너 이미지 (공식 사용자 가이드의 Dockerfile + 아키텍처 선택)
# 빌드: scripts/install.sh 가 호스트 아키텍처를 감지해 --build-arg EMULATOR_ARCH 를 넘긴다.
#   Apple silicon / ARM  → aarch64
#   Intel / AMD (WSL 포함) → x86_64
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
ARG EMULATOR_ARCH=x86_64
ADD https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator-${EMULATOR_ARCH}.rpm /tmp/aws-emulator.rpm
RUN rpm -i /tmp/aws-emulator.rpm && rm /tmp/aws-emulator.rpm \
    && mkdir -p /home/emulator && chown 1000 /home/emulator
USER 1000
ENV HOME=/home/emulator
EXPOSE 9297
ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0"]
