/* Run the APK's CPython in its own process with the editor's standard pipes. */
extern int Py_BytesMain(int argc, char **argv);

int main(int argc, char **argv) {
    return Py_BytesMain(argc, argv);
}
