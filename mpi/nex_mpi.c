/*
 * The shim of nex's `mpi` module (DESIGN §9.6): the one place that includes `mpi.h`.
 *
 * It is compiled by the MPI the program links against (`mpicc`, or the flags `pkg-config` gives),
 * so every handle and constant here is that implementation's own, read from its header. What it
 * hands nex is what nex can hold: a communicator as its Fortran handle (`MPI_Comm_c2f`), an `int32`
 * in every MPI, and a constant as an integer.
 *
 * `nex_mpi_init` is called by the program's C `main` before anything else runs. It initialises MPI
 * and tells the runtime which rank this process is and how to end the job (`nex_mpi_joined`): the
 * runtime ends it with `MPI_Abort` after a trap nothing caught or `stop n` with `n` not zero, and
 * with `MPI_Finalize` when `main` returns or `stop 0` runs.
 */

#include <mpi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* The runtime's: this process is rank `rank`, and the two ways its part in the job ends. */
extern void nex_mpi_joined(int32_t rank, void (*abort_job)(int32_t), void (*finalize_job)(void));

static void abort_job(int32_t code) {
    MPI_Abort(MPI_COMM_WORLD, code);
    /* MPI_Abort does not return; were an implementation's to, the process still ends. */
    _Exit(code);
}

static void finalize_job(void) {
    int finalized = 0;

    MPI_Finalized(&finalized);
    if (!finalized) MPI_Finalize();
}

void nex_mpi_init(void) {
    int provided = 0;
    int rank = 0;

    if (MPI_Init_thread(NULL, NULL, MPI_THREAD_SINGLE, &provided) != MPI_SUCCESS) {
        fputs("trap: mpi: MPI_Init_thread failed\n", stderr);
        exit(134);
    }

    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    nex_mpi_joined(rank, abort_job, finalize_job);
}

int32_t nex_mpi_world(void) { return (int32_t) MPI_Comm_c2f(MPI_COMM_WORLD); }

int32_t nex_mpi_self(void) { return (int32_t) MPI_Comm_c2f(MPI_COMM_SELF); }

int64_t nex_mpi_rank(int32_t comm) {
    int rank = 0;

    MPI_Comm_rank(MPI_Comm_f2c((MPI_Fint) comm), &rank);
    return rank;
}

int64_t nex_mpi_size(int32_t comm) {
    int size = 0;

    MPI_Comm_size(MPI_Comm_f2c((MPI_Fint) comm), &size);
    return size;
}

void nex_mpi_barrier(int32_t comm) { MPI_Barrier(MPI_Comm_f2c((MPI_Fint) comm)); }

int64_t nex_mpi_proc_null(void) { return MPI_PROC_NULL; }
