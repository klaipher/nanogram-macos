// Ed25519 for Sparkle updates, built by sparkle.py from Sparkle 1.21's own ed25519 sources
// (submodules/Sparkle/ed25519/src, the code SUSignatureVerifier checks with). Secrets travel on stdin only,
// never on the command line, and nothing secret is written anywhere but stdout.
//   public            stdin: 32-byte seed               stdout: 32-byte public key
//   sign <file>       stdin: 32-byte seed               stdout: 64-byte signature of the file
//   verify <file>     stdin: public key + signature     exit 0 if the signature is valid, 1 if not
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "ed25519.h"

static int read_exactly(unsigned char *buffer, size_t length) {
    size_t done = 0;
    while (done < length) {
        ssize_t got = read(STDIN_FILENO, buffer + done, length - done);
        if (got <= 0) {
            return 0;
        }
        done += (size_t)got;
    }
    unsigned char extra;
    return read(STDIN_FILENO, &extra, 1) == 0;
}

static int write_all(const unsigned char *buffer, size_t length) {
    return fwrite(buffer, 1, length, stdout) == length && fflush(stdout) == 0;
}

static const unsigned char *map_file(const char *path, size_t *length) {
    int fd = open(path, O_RDONLY);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) != 0) {
        return NULL;
    }
    *length = (size_t)info.st_size;
    static const unsigned char empty = 0;
    const unsigned char *data = *length == 0 ? &empty : mmap(NULL, *length, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    return data == MAP_FAILED ? NULL : data;
}

static void keypair(const unsigned char seed[32], unsigned char public_key[32], unsigned char private_key[64]) {
    ed25519_create_keypair(public_key, private_key, seed);
}

int main(int argc, char **argv) {
    unsigned char seed[32], public_key[32], private_key[64], signature[64];
    if (argc == 2 && strcmp(argv[1], "public") == 0) {
        if (!read_exactly(seed, sizeof seed)) {
            fprintf(stderr, "sparkle_ed25519: expected a 32-byte seed on stdin\n");
            return 2;
        }
        keypair(seed, public_key, private_key);
        memset(seed, 0, sizeof seed);
        memset(private_key, 0, sizeof private_key);
        return write_all(public_key, sizeof public_key) ? 0 : 2;
    }
    if (argc == 3 && (strcmp(argv[1], "sign") == 0 || strcmp(argv[1], "verify") == 0)) {
        size_t length = 0;
        const unsigned char *data = map_file(argv[2], &length);
        if (data == NULL) {
            fprintf(stderr, "sparkle_ed25519: cannot read %s\n", argv[2]);
            return 2;
        }
        if (strcmp(argv[1], "sign") == 0) {
            if (!read_exactly(seed, sizeof seed)) {
                fprintf(stderr, "sparkle_ed25519: expected a 32-byte seed on stdin\n");
                return 2;
            }
            keypair(seed, public_key, private_key);
            ed25519_sign(signature, data, length, public_key, private_key);
            memset(seed, 0, sizeof seed);
            memset(private_key, 0, sizeof private_key);
            return write_all(signature, sizeof signature) ? 0 : 2;
        }
        unsigned char input[96];
        if (!read_exactly(input, sizeof input)) {
            fprintf(stderr, "sparkle_ed25519: expected a public key and a signature on stdin\n");
            return 2;
        }
        return ed25519_verify(input + 32, data, length, input) ? 0 : 1;
    }
    fprintf(stderr, "usage: sparkle_ed25519 public | sign <file> | verify <file>\n");
    return 2;
}
