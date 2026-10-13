/*****************************************************************************/
/***************************** Include Files *********************************/
#include "peripherials_cfg_init.h"

uint32_t App_cfg_i2c_master(XIicPs *InstancePtr, uintptr_t DeviceId)
{
    xil_printf("Called Conf i2c master\r\n");
    uint32_t Status;
    XIicPs_Config *ConfigPtr;   /* Puntero a los datos de configuracion */

    /* Buscar la configuracion del dispositivo XIicPs */
    ConfigPtr = XIicPs_LookupConfig(DeviceId);
    
    if (ConfigPtr == NULL) {
        xil_printf("Error calling XIcPs_LookUp \r\n");
        sleep(2);
        return XFSBL_FAILURE;
    }
    xil_printf("Success calling XIcPs_LookUp \r\n");
    /* Inicializar el controlador I2C pasándole la instancia recibida */
    Status = XIicPs_CfgInitialize(InstancePtr, ConfigPtr, ConfigPtr->BaseAddress);
    if (Status != XFSBL_SUCCESS) {
        xil_printf("Error calling XIicPs_CfgInitialize \r\n");
        sleep(2);
        return XFSBL_FAILURE;
    }
    xil_printf("Success calling XIicPs_CfgInitialize \r\n");

    XIicPs_SetSClk(InstancePtr, IIC_SCLK_RATE);
    
    return XFSBL_SUCCESS;
}

s32 XIicPs_MasterRecvPolled(XIicPs *InstancePtr, u8 *MsgPtr, s32 ByteCount, u16 SlaveAddr)
{
    u32 IntrStatusReg;
    u32 Intrs;
    UINTPTR BaseAddr;
    s32 Result;
    s32 IsHold;
    s32 UpdateTxSize = 0;
    s32 ByteCountVar = ByteCount;
    u32 Platform;

    /*
     * Assert validates the input arguments.
     */
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(MsgPtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == (u32)XIL_COMPONENT_IS_READY);
    Xil_AssertNonvoid((u16)XIICPS_ADDR_MASK >= SlaveAddr);

    BaseAddr = InstancePtr->Config.BaseAddress;
    InstancePtr->RecvBufferPtr = MsgPtr;
    InstancePtr->RecvByteCount = ByteCountVar;

#if defined  (XCLOCKING)
    if (InstancePtr->IsClkEnabled == 0) {
        Xil_ClockEnable(InstancePtr->Config.RefClk);
        InstancePtr->IsClkEnabled = 1;
    }
#endif

    Platform = XGetPlatform_Info();

    if((ByteCountVar > XIICPS_FIFO_DEPTH) ||
        ((InstancePtr->IsRepeatedStart) !=0))
    {
        XIicPs_WriteReg(BaseAddr, XIICPS_CR_OFFSET,
                XIicPs_ReadReg(BaseAddr, (u32)XIICPS_CR_OFFSET) |
                        (u32)XIICPS_CR_HOLD_MASK);
        IsHold = 1;
    } else {
        IsHold = 0;
    }

    (void)XIicPs_SetupMaster(InstancePtr, RECVING_ROLE);

    /*
     * Clear the interrupt status register before use it to monitor.
     */
    IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);
    XIicPs_WriteReg(BaseAddr, XIICPS_ISR_OFFSET, IntrStatusReg);


    /*
     * Set up the transfer size register so the slave knows how much
     * to send to us.
     */
    if (ByteCountVar > (s32)XIICPS_MAX_TRANSFER_SIZE) {
        XIicPs_WriteReg(BaseAddr, XIICPS_TRANS_SIZE_OFFSET,
                XIICPS_MAX_TRANSFER_SIZE);
        ByteCountVar = (s32)XIICPS_MAX_TRANSFER_SIZE;
        UpdateTxSize = 1;
    }else {
        XIicPs_WriteReg(BaseAddr, XIICPS_TRANS_SIZE_OFFSET,
             ByteCountVar);
    }


    XIicPs_WriteReg(BaseAddr, XIICPS_ADDR_OFFSET, SlaveAddr);

    /*
     * Intrs keeps all the error-related interrupts.
     */
    Intrs = (u32)XIICPS_IXR_ARB_LOST_MASK | (u32)XIICPS_IXR_RX_OVR_MASK |
            (u32)XIICPS_IXR_RX_UNF_MASK | (u32)XIICPS_IXR_NACK_MASK;
    /*
     * Poll the interrupt status register to find the errors.
     */
    IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);

    while ((InstancePtr->RecvByteCount > 0) &&
            ((IntrStatusReg & Intrs) == 0U)) {

        while ((XIicPs_RxDataValid(InstancePtr)) != 0U) {
            if ((InstancePtr->RecvByteCount <
                XIICPS_DATA_INTR_DEPTH) && (IsHold != 0) &&
                (InstancePtr->IsRepeatedStart == 0) &&
                (UpdateTxSize == 0)) 
            {
                IsHold = 0;
                XIicPs_WriteReg(BaseAddr, XIICPS_CR_OFFSET,
                        XIicPs_ReadReg(BaseAddr,
                        XIICPS_CR_OFFSET) &
                        (~XIICPS_CR_HOLD_MASK));
            }
            XIicPs_RecvByte(InstancePtr);
            ByteCountVar --;

            if (Platform == (u32)XPLAT_ZYNQ) {
                if ((UpdateTxSize != 0) &&
                    (ByteCountVar == (XIICPS_FIFO_DEPTH + 1))) {
                    break;
                }
            }
        }
        if (Platform == (u32)XPLAT_ZYNQ) {
            if ((UpdateTxSize != 0) &&
                (ByteCountVar == (XIICPS_FIFO_DEPTH + 1))) {
                /* wait while fifo is full */
            while (XIicPs_RxFIFOFull(InstancePtr, ByteCountVar) != 0U) { ;
                }
                if ((InstancePtr->RecvByteCount - XIICPS_FIFO_DEPTH) >
                    (s32)XIICPS_MAX_TRANSFER_SIZE) {

                    XIicPs_WriteReg(BaseAddr,
                        XIICPS_TRANS_SIZE_OFFSET,
                        XIICPS_MAX_TRANSFER_SIZE);
                    ByteCountVar = (s32)XIICPS_MAX_TRANSFER_SIZE +
                            XIICPS_FIFO_DEPTH;
                } else {
                    XIicPs_WriteReg(BaseAddr,
                        XIICPS_TRANS_SIZE_OFFSET,
                        InstancePtr->RecvByteCount -
                        XIICPS_FIFO_DEPTH);
                    UpdateTxSize = 0;
                    ByteCountVar = InstancePtr->RecvByteCount;
                }
            }
        } else {
            if ((InstancePtr->RecvByteCount > 0) && (ByteCountVar == 0)) {
                /*
                 * Clear the interrupt status register before use it to
                 * monitor.
                 */
                IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);
                XIicPs_WriteReg(BaseAddr, XIICPS_ISR_OFFSET, IntrStatusReg);

                XIicPs_WriteReg(BaseAddr, XIICPS_ADDR_OFFSET, SlaveAddr);

                if ((InstancePtr->RecvByteCount) >  (s32)XIICPS_MAX_TRANSFER_SIZE) 
                {
                    XIicPs_WriteReg(BaseAddr,XIICPS_TRANS_SIZE_OFFSET, XIICPS_MAX_TRANSFER_SIZE);
                    ByteCountVar = (s32)XIICPS_MAX_TRANSFER_SIZE;
                } else 
                {
                    XIicPs_WriteReg(BaseAddr, XIICPS_TRANS_SIZE_OFFSET, InstancePtr->RecvByteCount);
                    UpdateTxSize = 0;
                    ByteCountVar = InstancePtr->RecvByteCount;
                }
            }
        }

        IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);
    }

    if (InstancePtr->IsRepeatedStart == 0) {
        XIicPs_WriteReg(BaseAddr, XIICPS_CR_OFFSET, XIicPs_ReadReg(BaseAddr,XIICPS_CR_OFFSET) & (~XIICPS_CR_HOLD_MASK));
    }

    if ((IntrStatusReg & Intrs) != 0U) {
		if ((IntrStatusReg & XIICPS_IXR_ARB_LOST_MASK) != 0U) {
			Result = (s32) XST_IIC_ARB_LOST;
		} else {
			Result = (s32)XST_FAILURE;
		}
	} else {
		Result = (s32)XST_SUCCESS;
	}

    return Result;
}

int32_t MasterSendI2C(XIicPs *InstancePtr, u8 *MsgPtr, s32 ByteCount, u16 SlaveAddr)
{
    u32 IntrStatusReg;
    u32 StatusReg;
    UINTPTR BaseAddr;
    u32 Intrs;
    s32 Status = (s32)XST_FAILURE;
    u32 timeout = 0;
    _Bool Value;

    /*
     * Assert validates the input arguments.
     */
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(MsgPtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == (u32)XIL_COMPONENT_IS_READY);
    Xil_AssertNonvoid((u16)XIICPS_ADDR_MASK >= SlaveAddr);

#if defined  (XCLOCKING)
    if (InstancePtr->IsClkEnabled == 0) {
        Xil_ClockEnable(InstancePtr->Config.RefClk);
        InstancePtr->IsClkEnabled = 1;
    }
#endif

    BaseAddr = InstancePtr->Config.BaseAddress;
    InstancePtr->SendBufferPtr = MsgPtr;
    InstancePtr->SendByteCount = ByteCount;

    if (((InstancePtr->IsRepeatedStart) != 0) || (ByteCount > XIICPS_FIFO_DEPTH)) {
        XIicPs_WriteReg(BaseAddr, XIICPS_CR_OFFSET, XIicPs_ReadReg(BaseAddr, (u32)XIICPS_CR_OFFSET) | (u32)XIICPS_CR_HOLD_MASK);
    }

    (void)XIicPs_SetupMaster(InstancePtr, SENDING_ROLE);

    /*
     * Intrs keeps all the error-related interrupts.
     */
    Intrs = (u32)XIICPS_IXR_ARB_LOST_MASK | (u32)XIICPS_IXR_TX_OVR_MASK |
        (u32)XIICPS_IXR_NACK_MASK;

    /*
     * Clear the interrupt status register before use it to monitor.
     */
    IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);
    XIicPs_WriteReg(BaseAddr, XIICPS_ISR_OFFSET, IntrStatusReg);

    /*
     * Transmit first FIFO full of data.
     */
    (void)TransmitFifoFill(InstancePtr);

    XIicPs_WriteReg(BaseAddr, XIICPS_ADDR_OFFSET, (u32)SlaveAddr);

    IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);

    /*
     * Continue sending as long as there is more data and
     * there are no errors.
     */
    Value = ((InstancePtr->SendByteCount > (s32)0) && ((IntrStatusReg & Intrs) == (u32)0U));
    while (Value != FALSE) {
        StatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_SR_OFFSET);

        /*
         * Wait until transmit FIFO is empty.
         */
        if ((StatusReg & XIICPS_SR_TXDV_MASK) != 0U) {
            IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);
            Value = ((InstancePtr->SendByteCount > (s32)0) && ((IntrStatusReg & Intrs) == (u32)0U));
            continue;
        }

        /*
         * Send more data out through transmit FIFO.
         */
        (void)TransmitFifoFill(InstancePtr);
        Value = ((InstancePtr->SendByteCount > (s32)0) && ((IntrStatusReg & Intrs) == (u32)0U));
    }

    /*
     * Check for completion of transfer.
     */
    while ((IntrStatusReg & XIICPS_IXR_COMP_MASK) != XIICPS_IXR_COMP_MASK){

        IntrStatusReg = XIicPs_ReadReg(BaseAddr, XIICPS_ISR_OFFSET);
        /*
         * If there is an error, tell the caller.
         */
        if ((IntrStatusReg & Intrs) != 0U) {
            if ((IntrStatusReg & XIICPS_IXR_ARB_LOST_MASK) != 0U) {
                Status = (s32) XST_IIC_ARB_LOST;
            }
            break;
        }
        /*
         * Timeout if stuck for more than 1 second
         */
        usleep(1);
        timeout++;
        if (timeout == TX_MAX_LOOPCNT) {
            break;
        }
    }

    if (InstancePtr->IsRepeatedStart == 0) {
        XIicPs_WriteReg(BaseAddr, XIICPS_CR_OFFSET,
                XIicPs_ReadReg(BaseAddr,XIICPS_CR_OFFSET) &
                        (~XIICPS_CR_HOLD_MASK));
    }
    
    /* Set the Status for XST_SUCCESS */
    if (((IntrStatusReg & Intrs) == 0U) && (timeout != TX_MAX_LOOPCNT)) {
        Status = (s32)XST_SUCCESS;
    }

    return Status;
}

//uint32_t Cfg_MuxInitChannel(XIicPs *InstancePtr, uint16_t MuxIicAddr, uint8_t WriteBuffer)
//{
//    uint32_t Status = 0;
//
//    /*Wait for the bus to be idle to star a transaction*/
//    while (XIicPs_BusIsBusy(InstancePtr));
//
//    /*Send data*/
//    Status = MasterSendI2C(InstancePtr, &WriteBuffer, 1, MuxIicAddr);
//    if (Status != XFSBL_SUCCESS){
//        return XFSBL_FAILURE;
//    }
//
//    /*Wait for the bus to be idle to star a transaction*/
//    while (XIicPs_BusIsBusy(InstancePtr));
//
//    return XFSBL_SUCCESS;
//}

uint32_t Cfg_MuxInitChannel(XIicPs *InstancePtr, uint16_t MuxIicAddr, uint8_t WriteBuffer)
{
    uint32_t Status = 0;

    while (XIicPs_BusIsBusy(InstancePtr));

    Status = MasterSendI2C(InstancePtr, &WriteBuffer, 1, MuxIicAddr);
    //Status = XIicPs_MasterSendPolled(InstancePtr, &WriteBuffer, 1, MuxIicAddr);


    if (Status != XFSBL_SUCCESS){
        xil_printf("Fallo envio al MUX. Direccion: 0x%X. Codigo de error: %d\r\n", MuxIicAddr, Status);
        return XFSBL_FAILURE;
    }

    while (XIicPs_BusIsBusy(InstancePtr));

    return XFSBL_SUCCESS;
}
uint32_t App_cfg_pll(XIicPs *InstancePtr)
{
    uint32_t Status;
    
    xil_printf("Entrando a configurar el mux\r\n");
    // 1. Configurar el canal del multiplexor
    Status = Cfg_MuxInitChannel(InstancePtr, CFG_MUX_ADDR_2, MUX_CHANNEL_5);
    if (Status != XFSBL_SUCCESS)
    {
        return XFSBL_FAILURE;
    }
    xil_printf("Success Cfg_MuxInitChannel in App_cfg_pll\r\n");

    // 2. Control de paginación para el Si5395
    uint8_t current_page = 0xFF; 
    uint16_t TotalRegs = SI5395_REVA_REG_CONFIG_NUM_REGS;
    
    for (uint16_t u08_Idx = 0u; u08_Idx < TotalRegs; u08_Idx++)
    {
        uint16_t full_address = si5395_reva_registers[u08_Idx].address;
        uint8_t page = (uint8_t)((full_address >> 8) & 0xFF); 
        uint8_t reg  = (uint8_t)(full_address & 0xFF);        
        uint8_t val  = si5395_reva_registers[u08_Idx].value;

        // ¿Ha cambiado la página en este registro?
        if (page != current_page)
        {
            uint8_t PageBuffer[2];
            PageBuffer[0] = 0x01; 
            PageBuffer[1] = page; 

            while (XIicPs_BusIsBusy(InstancePtr));
            Status = MasterSendI2C(InstancePtr, PageBuffer, 2, PLL_I2C_SLAVE_ADDR);
            if (Status != XFSBL_SUCCESS)
            {
                xil_printf("Error cambiando a pagina 0x%02X en App_cfg_pll\r\n", page);
                return XFSBL_FAILURE;
            }
            current_page = page; 
        }

        // 3. Preparar el mensaje con el registro interno de 8 bits y su valor correspondiente
        uint8_t SendBuffer[2];
        SendBuffer[0] = reg;
        SendBuffer[1] = val;

        while (XIicPs_BusIsBusy(InstancePtr));
        Status = MasterSendI2C(InstancePtr, SendBuffer, 2, PLL_I2C_SLAVE_ADDR);
        if (Status != XFSBL_SUCCESS)
        {
            xil_printf("Error escribiendo reg 0x%02X en App_cfg_pll, indice: %d\r\n", reg, u08_Idx);
            sleep(2);
            return XFSBL_FAILURE;
        }
        if(u08_Idx == 2){
        	xil_printf("Delay 300ms para el PLL\n");
        	usleep(300000);
        }
    }
    
    xil_printf("Success setting the new Si5395 PLL\r\n");
    return XFSBL_SUCCESS;
}

uint32_t App_cfg_i2cexpander(XIicPs *InstancePtr)
{
    uint32_t Status;
    
    // Configure i2c expander 0x21
    Status = Cfg_MuxInitChannel(InstancePtr, CFG_MUX_ADDR_1, MUX_CHANNEL_0);
    if (Status != XFSBL_SUCCESS)
    {
        return XFSBL_FAILURE;
    }
    xil_printf("Success Cfg_MuxInitChannel in App_cfg_i2cexpander\r\n");
    
    int16_t ByteCount = I2C_EXPANDER_REG_CONFIG_NUM_REGS;
    for (unsigned int u08_Idx = 0u; u08_Idx < ByteCount; u08_Idx++)
    {
        uint8_t SendBuffer[2];
        SendBuffer[0] =  i2c_expander_registers_21[u08_Idx].command;
        SendBuffer[1] =  i2c_expander_registers_21[u08_Idx].value;

        while (XIicPs_BusIsBusy(InstancePtr));
        Status = MasterSendI2C(InstancePtr, SendBuffer, 2, I2CEXP_I2C_SLAVE_ADDR_CLK_SEL);
        if (Status != XFSBL_SUCCESS)
        {
            xil_printf("Error calling MasterSendI2C in App_cfg_i2cexpander clk sel first write\r\n");
            sleep(2);
            return XFSBL_FAILURE;
        }
    }

    // Configure i2c expander 0x20
    Status = Cfg_MuxInitChannel(InstancePtr, CFG_MUX_ADDR_1, MUX_CHANNEL_4);
    if (Status != XFSBL_SUCCESS)
    {
        return XFSBL_FAILURE;
    }
    xil_printf("Success Cfg_MuxInitChannel in App_cfg_i2cexpander\r\n");

    ByteCount = I2C_EXPANDER_REG_CONFIG_NUM_REGS;
    for (unsigned int u08_Idx = 0u; u08_Idx < ByteCount; u08_Idx++)
    {
        uint8_t SendBuffer[2];
        SendBuffer[0] = i2c_expander_registers_20[u08_Idx].command;
        SendBuffer[1] = i2c_expander_registers_20[u08_Idx].value;

        while (XIicPs_BusIsBusy(InstancePtr));
        Status = MasterSendI2C(InstancePtr, SendBuffer, 2, I2CEXP_I2C_SLAVE_ADDR_QSFP);
        if (Status != XFSBL_SUCCESS)
        {
            xil_printf("Error calling MasterSendI2C in App_cfg_i2cexpander qsfp first write\r\n");
            sleep(2);
            return XFSBL_FAILURE;
        }
    }
    return XFSBL_SUCCESS;
}


uint32_t peripherials_cfg_init_main(void)
{        
    xil_printf("------------------------------------------------\r\n");
    xil_printf("---------------------BEGIN----------------------\r\n");
    uint32_t Status;
    
    // Suponiendo que tienes declarada IicInstance de forma global en tu cabecera para el canal 0
    Status = App_cfg_i2c_master(&IicInstance0, XPAR_PSU_I2C_0_DEVICE_ID);

    if (Status != XFSBL_SUCCESS){   
        xil_printf("Error calling App_cfg_i2c_master \r\n");
        sleep(1);
        return XFSBL_FAILURE;
    }
    xil_printf("------------------------------------------------\r\n");
    xil_printf("Success calling App_cfg_i2c_master i2c 0 Stage 1 completed\r\n");
    xil_printf("------------------------------------------------\r\n");

	    Status = App_cfg_i2c_master(&IicInstance1, XPAR_PSU_I2C_1_DEVICE_ID);

    if (Status != XFSBL_SUCCESS){   
        xil_printf("Error calling App_cfg_i2c_master \r\n");
        sleep(1);
        return XFSBL_FAILURE;
    }
    xil_printf("------------------------------------------------\r\n");
    xil_printf("Success calling App_cfg_i2c_master i2c 1 Stage 2 completed\r\n");
    xil_printf("------------------------------------------------\r\n");


    Status = App_cfg_pll(&IicInstance1);
    if (Status != XFSBL_SUCCESS){
        xil_printf("Error calling App_cfg_pll \r\n");
        sleep(1);
        return XFSBL_FAILURE;
    }
    xil_printf("------------------------------------------------\r\n");
    xil_printf("Success calling App_cfg_pll Stage 2 completed\r\n");
    xil_printf("------------------------------------------------\r\n");

    Status = App_cfg_i2cexpander(&IicInstance0);
    if (Status != XFSBL_SUCCESS){
        xil_printf("Error calling App_cfg_i2cexpander \r\n");
        sleep(1);
        return XFSBL_FAILURE;
    }
    xil_printf("------------------------------------------------\r\n");
    xil_printf("Success calling App_cfg_i2cexpander Stage 5 completed\r\n");
    xil_printf("------------------------------------------------\r\n");

    return XFSBL_SUCCESS;
}
